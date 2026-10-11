use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../lib";

BEGIN { plan skip_all => 'examples/content-negotiation requires Perl 5.40' if $] < 5.040 }

use PAGI::Test::Client;

# One notes resource for browsers, htmx and API clients: the representation
# comes from Accept, a full page or a fragment from HX-Request, and the input
# format from Content-Type. /health sits outside the negotiating mount.

my $app = do "$Bin/../examples/content-negotiation/app.pl" or die $@ || $!;
my $client = PAGI::Test::Client->new(app => $app, lifespan => 1);
$client->start;

my $json = { Accept => 'application/json' };
my $html = { Accept => 'text/html' };
my $htmx = { Accept => 'text/html', 'HX-Request' => 'true' };

my $res = $client->post('/notes', headers => $json, json => { text => 'buy <milk>' });
is [$res->status, $res->header('Location'), $res->json],
    [201, '/notes/1', { id => 1, text => 'buy <milk>' }], 'a JSON POST is a 201 with Location';

$res = $client->post('/notes', form => { text => 'call mum' });
is [$res->status, $res->header('Location')], [303, '/notes/'], 'a form POST redirects to the list';

$res = $client->post('/notes', headers => $htmx, form => { text => 'feed cat' });
is [$res->status, $res->header('Vary')], [200, 'HX-Request, Accept'], 'an htmx POST answers in place';
like $res->text, qr/\A<ul id="notes">.*feed cat/s, 'with the updated list fragment';

$res = $client->post('/notes', headers => { 'Content-Type' => 'text/plain' }, body => 'hi');
is [$res->status, $res->text], [415, 'The request body must be JSON or a form.'], 'any other body is a 415';

$res = $client->post('/notes', headers => { %$json, 'Content-Type' => 'application/vnd.api+json' },
    body => '{"text":"from an api client"}');
is $res->status, 201, 'a +json media type is read as JSON';

$res = $client->post('/notes', headers => $json, json => { title => 'no text' });
is $res->status, 400, 'a note without text is a 400';

for my $case ([$json, 'application/json', 'Accept'], [$html, 'text/html', 'HX-Request, Accept'],
              [{}, 'text/html', 'HX-Request, Accept']) {
    my ($headers, $type, $vary) = @$case;
    my $res = $client->get('/notes', headers => $headers);
    is [$res->status, $res->header('Content-Type'), $res->header('Vary')], [200, match(qr/\A\Q$type\E/), $vary],
        'GET /notes as ' . ($headers->{Accept} // 'no Accept') . ": $type, Vary $vary";
}

like $client->get('/notes', headers => $html)->text, qr/\A<!doctype html>/, 'a browser gets the full page';
$res = $client->get('/notes', headers => $htmx);
like $res->text, qr/\A<ul id="notes">/, 'htmx gets the fragment';

like $client->get('/notes/1', headers => $html)->text, qr/buy &#60;milk&#62;/,
    'note text is escaped in HTML';

$res = $client->head('/notes', headers => $json);
is [$res->status, $res->header('Vary')], [200, 'Accept'], 'HEAD has the same Vary';

$res = $client->get('/notes', headers => { Accept => 'image/png' });
is [$res->status, $res->header('Content-Type'), $res->header('Vary')],
    [406, 'application/problem+json', 'Accept'],
    'nothing acceptable is the app\'s own 406 problem, with Vary';
like $res->text, qr/"title"\s*:\s*"Not Acceptable"/, 'titled Not Acceptable';

for my $case ([$json, 'application/json'], [$html, 'text/html']) {
    my ($headers, $type) = @$case;
    my $res = $client->get('/notes/99', headers => $headers);
    is [$res->status, $res->header('Content-Type'), $res->header('Vary')], [404, match(qr/\A\Q$type\E/), 'Accept'],
        "a missing note is a 404 in $type, with Vary";
}

$res = $client->get('/health', headers => { Accept => 'image/png' });
is [$res->status, $res->text, $res->header('Vary')], [200, 'ok', undef],
    '/health is outside the negotiation: no 406, no Vary';

$client->stop;
done_testing;
