use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use PAGI::Test::Client;

# examples/request-class: one middleware sets the application's Request
# class, and a plain route, an Endpoint::HTTP method and a mounted route all
# receive it.

if ($] < 5.040) {
    plan skip_all => 'examples/request-class requires Perl 5.40';
    exit 0;
}

my $app = do "$Bin/../examples/request-class/app.pl";
is($@, '', 'the example loads');
isa_ok($app, 'PAGI::Compose');

my $client = PAGI::Test::Client->new(app => $app, lifespan => 1);
$client->start;

# A plain route: $request->notes reaches the startup store.
my $res = $client->post('/notes', json => { text => 'buy milk' });
is($res->status, 201, 'a note is created at a plain route');
is($res->json, { id => 1, text => 'buy milk' }, 'in the store $request->notes returns');
is($res->header('location'), '/notes/1', 'with a link to it');
$client->post('/notes', json => { text => "note $_" }) for 2 .. 3;

# A plain route: $request->page reads and checks ?page=.
is($client->get('/notes')->json,
    { page => 1, notes => [{ id => 1, text => 'buy milk' }, { id => 2, text => 'note 2' }] },
    'no ?page= is page 1');
is($client->get('/notes?page=2')->json, { page => 2, notes => [{ id => 3, text => 'note 3' }] },
    '?page=2 is the second page');
is($client->get('/notes?page=0')->json->{page}, 1, 'a page below 1 is page 1');
is($client->get('/notes?page=x')->json->{page}, 1, 'a page that is not a number is page 1');

# An Endpoint::HTTP class: its methods get the subclass too.
$res = $client->get('/notes/1');
is($res->status, 200, 'the endpoint answers');
is($res->json, { id => 1, text => 'buy milk' }, 'through $request->notes');
is($client->get('/notes/9')->status, 404, 'a missing note is a 404');

# A mounted route: the class travels in the scope.
is($client->get('/admin/stats')->json, { notes => 3 }, 'a route inside a mount gets it');

is($client->delete('/notes/1')->status, 204, 'the endpoint deletes');
is($client->get('/admin/stats')->json, { notes => 2 }, 'and the store agrees');

$client->stop;

done_testing;
