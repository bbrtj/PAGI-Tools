use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use PAGI::Compose qw(compose);
use PAGI::Response qw(response);
use PAGI::Routing qw(mount route router);
use PAGI::Routing::URL qw(path_for);
use PAGI::Test::Client;

# A mount is a barrier to any application and transparent to a Router: the
# routing tree, its names and path_for see into a mounted Router, never into
# a mounted application, a Compose included.

my $where = sub {
    my ($request) = @_;
    return response('Text', join ' ', map { eval { path_for($request, $_) } // "$_:unknown" } qw(a /a /r/a /c/a));
};
my $app = compose(routes => [
    mount('/c', name => 'c', app => compose(routes => [route('/a' => $where, name => 'a')])),
    mount('/r', name => 'r', app => router(routes => [route('/a' => $where, name => 'a')])),
    route('/out' => $where),
    route('/leaf' => compose(routes => [route('/' => sub { response('Text', 'never') })])),
]);
my $client = PAGI::Test::Client->new(app => $app);

subtest 'a mounted Router is part of the application' => sub {
    ok(exists $app->named_routes->{'/r/a'}, 'its routes are in named_routes');
    is($client->get('/r/a')->text, '/r/a /a:unknown /r/a /c/a:unknown',
        'its handlers resolve names in the enclosing namespace');
};

subtest 'a mounted application is a separate application' => sub {
    ok(!exists $app->named_routes->{'/c/a'}, 'its routes are not in named_routes');
    is([map { $_->kind . ' ' . $_->template } grep { $_->template =~ m{^/c} } $app->route_table],
        ['mount /c'], 'route_table has one mount entry for it');
    is($client->get('/out')->text, 'a:unknown /a:unknown /r/a /c/a:unknown',
        'the enclosing application cannot reach its names');
    is($client->get('/c/a')->text, '/c/a /c/a /r/a:unknown /c/a:unknown',
        'its own handlers resolve only its own names, rendered under the mount');
};

subtest 'an application given to route answers exactly that path, unchanged' => sub {
    is($client->get('/leaf')->status, 404,
        'a Compose as a route endpoint sees the full path /leaf, which none of its routes match');
};

done_testing;
