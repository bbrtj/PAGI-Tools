use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../lib";

BEGIN { plan skip_all => 'examples/content-negotiation requires Perl 5.40' if $] < 5.040 }

use PAGI::Test::Client;

# One notes resource for browsers and API clients: the representation comes
# from Accept, the input format from Content-Type.

my $app = do "$Bin/../examples/content-negotiation/app.pl" or die $@ || $!;
my $client = PAGI::Test::Client->new(app => $app, lifespan => 1);
$client->start;

my $json = { Accept => 'application/json' };

my $res = $client->post('/notes', headers => $json, json => { text => 'buy <milk>' });
is [$res->status, $res->header('Location'), $res->json],
    [201, '/notes/1', { id => 1, text => 'buy <milk>' }], 'a JSON POST is a 201 with Location';

$res = $client->post('/notes', form => { text => 'call mum' });
is [$res->status, $res->header('Location')], [303, '/notes'], 'a form POST redirects to the list';

$res = $client->post('/notes', headers => { 'Content-Type' => 'text/plain' }, body => 'hi');
is $res->status, 415, 'any other body is a 415';

for my $case ([$json, 'application/json'], [{ Accept => 'text/html' }, 'text/html'], [{}, 'text/html']) {
    my ($headers, $type) = @$case;
    my $res = $client->get('/notes', headers => $headers);
    is [$res->status, $res->header('Content-Type'), $res->header('Vary')], [200, match(qr/\A\Q$type\E/), 'Accept'],
        'GET /notes as ' . ($headers->{Accept} // 'no Accept') . ": $type, with Vary";
}

like $client->get('/notes/1', headers => { Accept => 'text/html' })->text, qr/buy &#60;milk&#62;/,
    'note text is escaped in HTML';

$res = $client->head('/notes', headers => $json);
is [$res->status, $res->header('Vary')], [200, 'Accept'], 'HEAD has the same Vary';

$res = $client->get('/notes', headers => { Accept => 'image/png' });
is [$res->status, $res->header('Vary')], [406, 'Accept'], 'nothing acceptable is a 406, with Vary';

for my $case ([$json, 'application/json'], [{ Accept => 'text/html' }, 'text/html']) {
    my ($headers, $type) = @$case;
    my $res = $client->get('/notes/99', headers => $headers);
    is [$res->status, $res->header('Content-Type'), $res->header('Vary')], [404, match(qr/\A\Q$type\E/), 'Accept'],
        "a missing note is a 404 in $type, with Vary";
}

$client->stop;
done_testing;
