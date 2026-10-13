use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../lib";

BEGIN { plan skip_all => 'examples/signed-requests requires Perl 5.40' if $] < 5.040 }

use Digest::SHA qw(hmac_sha256_hex sha256_hex);
use PAGI::Test::Client;

# A middleware checks a signature over the whole body, then the routes read
# that body again: a JSON event through PAGI::Request, an artifact streamed
# to disk, small (in memory) or large (spooled to a temporary file).

local $ENV{SIGNING_SECRET} = 'test-secret';
my $app = do "$Bin/../examples/signed-requests/app.pl" or die $@ || $!;
my $client = PAGI::Test::Client->new(app => $app, lifespan => 1);
$client->start;

sub signed {
    my ($body, $secret) = @_;
    return { 'X-Signature' => 'sha256=' . hmac_sha256_hex(sha256_hex($body), $secret // 'test-secret') };
}

my $event = '{"build":42,"status":"passed"}';
my $res = $client->post('/signed/events', body => $event,
    headers => { %{ signed($event) }, 'Content-Type' => 'application/json' });
is $res->status, 202, 'a signed event is accepted';
is $res->json, { ok => 1, build => 42 }, 'read as JSON after the check';

is $client->post('/signed/events', body => $event)->status, 401, 'an unsigned event is refused';
is $client->post('/signed/events', body => $event, headers => signed($event, 'wrong'))->status, 401,
    'so is one signed with another secret';
is $client->post('/signed/events', body => 'not json', headers => signed('not json'))->status, 400,
    'a signed body that is not JSON is the stock 400';
is $client->get('/signed/events')->status, 401, 'the middleware answers before the router: a GET is unsigned';
is $client->get('/events')->json, [{ build => 42, status => 'passed' }], 'only the signed event was recorded';

for my $case (['small', join('', map { chr } 0 .. 255) x 4], ['large', join('', map { chr($_ % 256) } 0 .. 2_000_000)]) {
    my ($size, $bytes) = @$case;
    $res = $client->post('/signed/artifacts/build.tar', body => $bytes, headers => signed($bytes));
    is $res->status, 201, "a signed $size artifact is accepted";
    is $res->json, { bytes => length $bytes, sha256 => sha256_hex($bytes) }, 'and stored exactly as signed';
}

$client->stop;
done_testing;
