use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use PAGI::Test::Client;

# Tiny, the small framework in examples/framework-on-tools/lib, built on
# PAGI-Tools: each test pins one seam the framework stands on.

my $app = do "$Bin/../examples/framework-on-tools/app.pl";
is($@, '', 'the example loads');
isa_ok($app, 'PAGI::Compose');

my $client = PAGI::Test::Client->new(app => $app, lifespan => 1);
$client->start;

# Plain-value returns: a string is HTML, an arrayref is JSON.
my $res = $client->get('/');
is($res->status, 200, 'the index is served');
like($res->content_type, qr{^text/html}, 'a returned string is HTML');
like($res->text, qr/Tiny notes/, 'with its body');

$res = $client->get('/notes');
is($res->status, 200, 'the list is served');
is($res->json, [], 'a returned arrayref is JSON');

# The around hook and the plugin edit the response after call_next.
is($res->header('x-powered-by'), 'Tiny on PAGI-Tools', 'the around hook added its header');
like($res->header('server-timing'), qr/^notes;dur=\d/, 'and the Timing plugin added Server-Timing');

# A service built at startup, read through the framework's Request subclass.
$res = $client->post('/notes', json => { text => 'buy milk' });
is($res->status, 201, 'a note is created');
is($res->json, { id => 1, text => 'buy milk' }, 'in the startup-built store');

$res = $client->get('/notes/1');
is($res->json, { id => 1, text => 'buy milk' }, 'and read back by its id through param()');

# A thrown exception class mapped to a response.
$res = $client->get('/notes/9');
is($res->status, 404, 'a thrown Note::NotFound is a 404');
is($res->json, { error => 'no such note', id => 9 }, 'rendered by the on_error mapping');
is($res->header('x-powered-by'), 'Tiny on PAGI-Tools', 'and still passes through the around hook');

# A typed path parameter: the constraint turns a non-integer into a miss.
is($client->get('/notes/x')->status, 404, 'a non-integer id does not match the route');

# The before hook short-circuits.
$res = $client->get('/admin');
is($res->status, 403, 'the before hook refuses /admin');
is($res->json, { error => 'forbidden' }, 'with its own answer');
is($client->get('/admin?token=letmein')->json, { admin => 'ok' }, 'and lets a token through');

# Delete, then the stock 405 from the Router.
is($client->delete('/notes/1')->status, 204, 'a note is deleted');
$res = $client->put('/notes/1');
is($res->status, 405, 'an unsupported method is the router 405');
is($res->header('allow'), 'GET, HEAD, DELETE', 'with Allow merged across the two routes on that path');

# The raw escape hatch.
$res = $client->get('/raw');
is($res->status, 200, 'the raw application answers');
is($res->text, "raw PAGI\n", 'with its hand-sent chunks');

# The OpenAPI document generated from the Router.
$res = $client->get('/openapi.json');
is($res->status, 200, 'the OpenAPI document is served');
my $doc = $res->json;
is($doc->{info}{title}, 'Tiny notes', 'with its title');
is([sort keys %{ $doc->{paths} }],
    ['/', '/admin', '/notes', '/notes/{id}', '/openapi.json', '/raw'],
    'listing every route path');
is([sort keys %{ $doc->{paths}{'/notes/{id}'} }], ['delete', 'get'], 'with each method');
is($doc->{paths}{'/notes/{id}'}{get}{parameters},
    [{ name => 'id', in => 'path', required => T(), schema => { type => 'integer' } }],
    'and the typed path parameter from its constraint');
is($doc->{paths}{'/notes'}{get}{summary}, 'List the notes', 'and the route desc as summary');
is($doc->{paths}{'/notes'}{get}{operationId}, 'notes', 'and the route name as operationId');

done_testing;
