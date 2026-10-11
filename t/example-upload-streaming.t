use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../lib";

BEGIN { plan skip_all => 'examples/upload-streaming requires Perl 5.40' if $] < 5.040 }

use Digest::SHA qw(sha256_hex);
use PAGI::Test::Client;

# Bytes or text: a binary upload kept exactly, CSV imports decoded by the
# client's charset (strict), a lenient transform.

my $app = do "$Bin/../examples/upload-streaming/app.pl" or die $@ || $!;
my $client = PAGI::Test::Client->new(app => $app, lifespan => 1);
$client->start;

my $zip = "PK\x03\x04" . join('', map { chr } 0 .. 255) x 40;
my $res = $client->put('/files/a.zip', body => $zip);
is [$res->status, $res->json->{bytes}, $res->json->{sha256}], [201, length $zip, sha256_hex($zip)],
    'a binary upload is stored exactly as sent';

$res = $client->put('/files/empty.bin', body => '');
is $res->status, 400, 'an empty upload is refused';

is $client->put('/files/..', body => 'x')->status, 404, 'a name with no letters before a dot never matches';

my %csv = (
    'cp1252'               => ["name,city\nJos\xE9,M\xFCnchen\nAna,Lisboa\n", 'windows-1252'],
    'UTF-8 with a BOM'     => ["\xEF\xBB\xBFname\nA\nB", 'utf-8'],
    'UTF-16LE with a BOM'  => ["\xFF\xFE" . join('', map { "$_\0" } split //, "name\nA\nB\n"), 'utf-16'],
);
for my $label (sort keys %csv) {
    my ($body, $charset) = @{$csv{$label}};
    $res = $client->post('/import', headers => { 'Content-Type' => "text/csv; charset=$charset" }, body => $body);
    is [$res->status, $res->json], [200, { rows => 3 }], "$label: three rows";
}

$res = $client->post('/import', headers => { 'Content-Type' => 'text/csv; charset=utf-8' }, body => '');
is [$res->status, $res->json], [200, { rows => 0 }], 'an empty CSV has no rows';

$res = $client->post('/import', headers => { 'Content-Type' => 'text/csv; charset=x-bogus' }, body => "a\n");
is $res->status, 415, 'a charset the stream cannot decode is a 415';

$res = $client->post('/import', headers => { 'Content-Type' => 'text/csv; charset=utf-8' }, body => $zip);
is $res->status, 400, 'a binary body posted as text is a 400';

$res = $client->post('/shout', headers => { 'Content-Type' => 'text/plain; charset=utf-8' }, body => "w\xC3\xB6rld \xFF!");
is $res->content, "W\xC3\x96RLD \xEF\xBF\xBD!", 'shout: a bad byte becomes U+FFFD, not an error';

$client->stop;
done_testing;
