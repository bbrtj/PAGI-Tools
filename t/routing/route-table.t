use strict;
use warnings;
use Test2::V0;
use Scalar::Util qw(refaddr);
use Types::Standard qw(Int);
use lib 'lib';
use PAGI::Routing qw(router route websocket sse mount middleware);
use PAGI::Compose qw(compose);
use PAGI::Response qw(response);
use PAGI::Test::Client;

sub PersonId { Int }    # a compact provider, {person_id:&PersonId}

my $ok = sub { response('Text', 'ok') };
sub table { my %by; $by{ $_->template . ' ' . $_->kind } = $_ for $_[0]->route_table; \%by }

subtest 'a flat Router: one entry per route, in order' => sub {
    my $r = router(routes => [
        route('/' => $ok, name => 'home', desc => 'Home'),
        route('/notes' => $ok, methods => ['POST'], name => 'add'),
    ]);
    my @e = $r->route_table;
    is [map { $_->template } @e], ['/', '/notes'], 'templates in declaration order';
    is [map { $_->kind } @e], ['route', 'route'], 'kinds';
    is $e[0]->methods, ['GET', 'HEAD'], 'GET implies HEAD';
    is $e[1]->methods, ['POST'], 'declared methods';
    is [$e[0]->name, $e[0]->address, $e[0]->desc, $e[0]->pattern], ['home', '/home', 'Home', '/'], 'name, address, desc, pattern';
    isa_ok $e[0], ['PAGI::Routing::RouteEntry'];
};

subtest 'nested mounts compose template, pattern, parameters and address' => sub {
    my $r = router(routes => [
        mount('/people/{person_id:&PersonId}', name => 'people', routes => [
            route('/notes/{id:&Int}' => $ok, name => 'show'),
        ]),
    ]);
    my ($e) = $r->route_table;
    is $e->template, '/people/{person_id}/notes/{id}', 'template composed and stripped';
    is $e->pattern, '/people/{person_id:&PersonId}/notes/{id:&Int}', 'pattern composed and kept';
    is $e->parameters, ['person_id', 'id'], "the mount's capture first";
    is [$e->name, $e->address], ['show', '/people/show'], 'name as declared, address the named_routes key';
    ok exists $r->named_routes->{ $e->address }, 'the address is a named_routes key';
};

subtest 'constraints as declared' => sub {
    my $check = sub { $_[0] =~ /\A[a-z]+\z/ };
    my $r = router(routes => [
        route('/a/{x:&Int}/{y:\d+}/{z}/{w}/{v}' => $ok,
            constraints => { z => qr/\d+/, w => $check, x => Int }),
    ]);
    my ($e) = $r->route_table;
    my $c = $e->constraints;
    is scalar @{ $c->{x} }, 2, 'an inline and an explicit constraint on one capture';
    is refaddr($c->{x}[0]), refaddr(Int), 'a compact provider gives its type object, first';
    is $c->{y}, ['\d+'], 'an inline regexp gives its source string';
    is ref $c->{z}[0], 'Regexp', 'an explicit Regexp is the one given';
    is refaddr($c->{w}[0]), refaddr($check), 'a coderef is the coderef';
    ok !exists $c->{v}, 'an unconstrained capture is absent';
};

subtest 'middleware outermost first, as declared' => sub {
    my ($app, $root, $mount, $child, $leaf) = map { middleware(sub { $_[0] }) } 1 .. 5;
    my $c = compose(middleware => [$app], routes => [
        mount('/', app => router(middleware => [$root], routes => [
            mount('/p', middleware => [$mount], routes => [
                route('/x' => $ok, middleware => [$leaf]),
            ]),
            mount('/api', app => router(middleware => [$child], routes => [route('/y' => $ok)])),
        ])),
    ]);
    my $t = table($c);
    is [map { refaddr $_ } @{ $t->{'/p/x route'}->middleware }], [map { refaddr $_ } $app, $root, $mount, $leaf],
        'application, root Router, Mount, Route';
    is [map { refaddr $_ } @{ $t->{'/api/y route'}->middleware }], [map { refaddr $_ } $app, $root, $child],
        'application, root Router, child Router';

    my ($c1, $c2, $c3, $c4, $c5) = map { middleware(sub { $_[0] }) } 1 .. 5;
    my $deep = compose(middleware => [$c1], routes => [
        mount('/', app => router(middleware => [$c2], routes => [
            mount('/p', middleware => [$c3], app => router(middleware => [$c4], routes => [
                route('/x' => $ok, middleware => [$c5]),
            ])),
        ])),
    ]);
    is [map { refaddr $_ } @{ ($deep->route_table)[0]->middleware }], [map { refaddr $_ } $c1, $c2, $c3, $c4, $c5],
        'all five layers on one path: Compose, Router, Mount, child Router, Route';
};

subtest 'WebSocket and SSE routes' => sub {
    my $r = router(routes => [websocket('/ws' => sub { }), sse('/events' => sub { })]);
    my @e = $r->route_table;
    is [map { $_->kind } @e], ['websocket', 'sse'], 'their kinds';
    is [map { $_->methods } @e], [undef, undef], 'no methods';
};

subtest 'opaque and Router-valued mounts' => sub {
    my $r = router(routes => [
        mount('/legacy', app => sub { }, name => 'legacy'),
        mount('/c', app => compose(routes => [route('/z' => $ok)])),
        mount('/api', app => router(routes => [route('/y' => $ok)])),
    ]);
    my @e = $r->route_table;
    is [map { $_->kind . ' ' . $_->template } @e], ['mount /legacy', 'mount /c', 'route /api/y'],
        'an opaque app is one mount entry (a Compose too); a Router contributes its routes';
    is [$e[0]->name, $e[0]->address], ['legacy', '/legacy'], "a mount entry's own name and address";
};

subtest 'unnamed routes are listed' => sub {
    my $r = router(routes => [route('/a' => $ok), route('/b' => $ok, name => 'b')]);
    is [map { $_->template } $r->route_table], ['/a', '/b'];
};

subtest 'entries hand out copies' => sub {
    my $shared = { summary => 'S' };
    my $child = router(routes => [route('/n/{id:&Int}' => $ok, methods => ['POST'],
        middleware => [middleware(sub { $_[0] })], meta => { openapi => $shared, tool => { x => 1 } })]);
    my $r = router(routes => [mount('/a', app => $child), mount('/b', app => $child)]);
    my ($e, $other) = $r->route_table;
    my %got = (methods => $e->methods, parameters => $e->parameters, constraints => $e->constraints,
               middleware => $e->middleware, meta => $e->meta);
    push @{ $got{methods} }, 'JUNK';
    push @{ $got{parameters} }, 'junk';
    push @{ $got{constraints}{id} }, 'junk';
    $got{constraints}{new} = ['junk'];
    push @{ $got{middleware} }, 'junk';
    $got{meta}[0]{tool} = 'junk';
    push @{ $got{meta} }, 'junk';
    for my $view (['a second read of the same entry', $e], ['the other placement', $other],
                  ['a fresh route_table', ($r->route_table)[0]]) {
        my ($label, $x) = @$view;
        is [$x->methods, $x->parameters, scalar @{ $x->constraints->{id} }, (exists $x->constraints->{new} ? 1 : 0),
            scalar @{ $x->middleware }, scalar @{ $x->meta }, $x->meta->[0]{tool}],
           [['POST'], ['id'], 1, 0, 1, 1, { x => 1 }], "$label is unchanged";
    }
    is refaddr($e->meta->[0]{openapi}), refaddr($shared), 'a value nested in meta is the shared original';
};

subtest 'Compose and its Router agree but for the application middleware' => sub {
    my $app_mw = middleware(sub { $_[0] });
    my $c = compose(middleware => [$app_mw], routes => [route('/a' => $ok, name => 'a')]);
    my ($via_compose) = $c->route_table;
    my ($via_router)  = $c->router->route_table;
    is [$via_compose->template, $via_compose->address], [$via_router->template, $via_router->address];
    is scalar @{ $via_compose->middleware } - scalar @{ $via_router->middleware }, 1, 'one more: the application middleware';
};

subtest 'request-time parity: pattern and address match the match record' => sub {
    my %seen;
    my $record = sub { my ($req) = @_; my $m = $req->scope->{'pagi.routing'}{frames}[-1]{match};
                       $seen{ $m->{route} } = $m->{name}; response('Text', 'ok') };
    my $c = compose(routes => [
        route('/' => $record, name => 'home'),
        mount('/people/{person_id:&PersonId}', name => 'people', routes => [
            route('/notes/{id:\d+}' => $record, name => 'show'),
            route('/files/*path' => $record),
        ]),
    ]);
    my $client = PAGI::Test::Client->new(app => $c);
    $client->get($_) for '/', '/people/3/notes/4', '/people/3/files/a/b';
    for my $e ($c->route_table) {
        ok exists $seen{ $e->pattern }, $e->pattern . ' is the request-time route';
        is $seen{ $e->pattern }, $e->address, 'and its address the request-time name';
    }
};

subtest 'an unrestricted route' => sub {
    my $r = router(routes => [route('/raw' => $ok, methods => '*')]);
    is(($r->route_table)[0]->methods, '*');
};

subtest 'a child Router mounted twice' => sub {
    my $child = router(routes => [route('/show' => $ok, name => 'show')]);
    my $r = router(routes => [mount('/api', app => $child, name => 'api'), mount('/v2', app => $child)]);
    my @e = $r->route_table;
    is [map { $_->template } @e], ['/api/show', '/v2/show'], 'two entries';
    is refaddr($e[0]->node), refaddr($e[1]->node), 'the same node';
    is [map { $_->address } @e], ['/api/show', '/show'], 'their own addresses';
};

subtest "templates: root mounts, '/' in a mount, colon, wildcard, braces" => sub {
    my $r = router(routes => [
        mount('/', routes => [route('/x' => $ok)]),
        mount('/api', routes => [route('/' => $ok)]),
        route('/users/:id' => $ok),
        route('/files/*path' => $ok),
        route('/a/{code:\d{3}}/b' => $ok),
    ]);
    is [map { $_->template } $r->route_table], ['/x', '/api/', '/users/{id}', '/files/{path}', '/a/{code}/b'];
};

subtest 'order is depth-first, in declaration order' => sub {
    my $r = router(routes => [
        route('/a' => $ok),
        mount('/m', routes => [route('/b' => $ok), mount('/n', routes => [route('/c' => $ok)]), route('/d' => $ok)]),
        route('/e' => $ok),
    ]);
    is [map { $_->template } $r->route_table], ['/a', '/m/b', '/m/n/c', '/m/d', '/e'];
};

subtest 'predicate records accept declared, and nothing else new' => sub {
    my $r = router(routes => [route('/n/{id:&Int}' => $ok, name => 'n')]);
    is $r->path_for('/n', { id => 5 }), '/n/5', 'a named route still renders after its Pattern is rebuilt';
    my $records = sub { my ($fields) = @_;
        PAGI::Routing::Pattern->new(path => '/x/{id}', mode => 'route', constraints => {},
            _predicate_records => { id => [{ check => sub { 1 }, %$fields }] }) };
    ok lives { $records->({ declared => 'x' }) }, 'a declared field is accepted' or diag $@;
    like dies { $records->({ other => 1 }) }, qr/unknown field 'other'/, 'an unknown record field is still refused';
};

subtest 'meta: composed outermost first, objects kept, validated, copied' => sub {
    my $object = bless {}, 'Local::Description';
    my $r = router(routes => [
        mount('/notes', meta => { openapi => { tags => ['notes'] } }, routes => [
            mount('/in', routes => [
                route('/x' => $ok, meta => { openapi => { summary => 'X' }, tool => $object }),
            ]),
        ]),
    ]);
    my ($e) = $r->route_table;
    is $e->meta, [{ openapi => { tags => ['notes'] } }, { openapi => { summary => 'X' }, tool => $object }],
        'each level with meta, outermost first; a level without it left out';
    is refaddr($e->meta->[1]{tool}), refaddr($object), 'an object value is the same object';
    like dies { route('/y' => $ok, meta => 'nope') }, qr/meta/, 'a non-hashref meta is refused';
    my $route = route('/z' => $ok, meta => { a => 1 });
    $route->meta->{a} = 2;
    is $route->meta, { a => 1 }, "a Route's meta accessor gives a copy";
    is route('/q' => $ok)->meta, {}, 'an empty hash when none was given';
};

subtest 'meta is not in the request-time match record' => sub {
    my $match;
    my $c = compose(routes => [route('/m' => sub { $match = $_[0]->scope->{'pagi.routing'}{frames}[-1]{match}; response('Text', 'ok') },
        meta => { openapi => { summary => 'M' } })]);
    PAGI::Test::Client->new(app => $c)->get('/m');
    ok !grep({ /meta/ } keys %$match), 'no meta key in the match record';
};

done_testing;
