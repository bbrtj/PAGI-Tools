#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Test2::V0;
use Future;
use Scalar::Util qw(refaddr);

use lib 'lib';
use PAGI::Compose qw(compose);
use PAGI::Response qw(response);
use PAGI::Routing qw(mount route router);
use PAGI::Routing::Resolver;
use PAGI::Routing::URL qw(path_for url_for);
use PAGI::Test::Client;
use PAGI::Test::ConnectionState;

# An opaque application: the resolver knows its prefix and nothing below it.
my $files = sub { return Future->done };

sub _frame {
    my ($resolver, %changes) = @_;
    return {
        resolver          => $resolver,
        logical_namespace => '/',
        captures          => {},
        mounts            => [],
        match             => undef,
        %changes,
    };
}

sub _scope {
    my ($type, $resolver, %changes) = @_;
    return {
        # A server gives every WebSocket and SSE scope its connection.
        ($type eq 'websocket' || $type eq 'sse'
            ? ('pagi.connection' => PAGI::Test::ConnectionState->new(websocket => $type eq 'websocket'))
            : ()),
        type           => $type,
        method         => 'GET',
        path           => '/',
        raw_path       => '/',
        headers        => [['host', 'example.test']],
        scheme         => 'http',
        root_path      => '',
        'pagi.routing' => {
            version => 1,
            frames  => [_frame($resolver)],
        },
        %changes,
    };
}

sub _routing {
    return router(routes => [
        route('/' => sub { }, name => 'home'),
        mount('/static', app => $files, name => 'static'),
        mount('/api', routes => [
            route('/notes' => sub { }, name => 'notes'),
        ], name => 'api'),
        mount('/users/{user_id:\d+}', routes => [
            route('/' => sub { }, name => 'index'),
        ], name => 'user'),
    ]);
}

subtest 'a named opaque Mount is a reverse target for its prefix' => sub {
    my $routing = _routing();
    is($routing->path_for('static'), '/static', 'a relative name gives the prefix');
    is($routing->path_for('/static'), '/static', 'an absolute name gives the prefix');
};

subtest 'path renders below a named Mount' => sub {
    my $routing = _routing();
    my @cases = (
        ['app.css',     '/static/app.css',       'a file below the prefix'],
        ['/app.css',    '/static/app.css',       'a leading slash is dropped'],
        ['//app.css',   '/static/app.css',       'every leading slash is dropped'],
        ['',            '/static/',              'an empty path gives the prefix with a slash'],
        ['/',           '/static/',              'a lone slash gives the same'],
        ['css/a b.css', '/static/css/a%20b.css', 'each segment is percent-encoded'],
        ['ü.css',       '/static/%C3%BC.css',    'non-ASCII is UTF-8 percent-encoded'],
        ['../x',        '/static/../x',          'dot segments pass through, as for a route wildcard'],
    );
    for my $case (@cases) {
        my ($path, $expected, $label) = @$case;
        is($routing->path_for('static', { path => $path }), $expected, $label);
    }
};

subtest 'a bad path and an extra parameter croak' => sub {
    my $routing = _routing();
    like(dies { $routing->path_for('static', { path => undef }) },
        qr/path parameter 'path' for route '\/static' must be a defined scalar/,
        'an undef path croaks');
    like(dies { $routing->path_for('static', { other => 1 }) },
        qr/unexpected path parameter 'other'/,
        'any other parameter croaks');
};

subtest 'path values that are not plain segments' => sub {
    my $routing = _routing();
    is($routing->path_for('static', { path => 'a?b#c' }), '/static/a%3Fb%23c',
        'query and fragment characters are encoded into the path');
    like(dies { $routing->path_for('static', { path => [] }) },
        qr/path parameter 'path' for route '\/static' must be a defined scalar/,
        'a reference croaks');
};

subtest 'a routes Mount is a reverse target too' => sub {
    my $routing = _routing();
    is($routing->path_for('/api'), '/api', 'its name gives the prefix');
    is($routing->path_for('/api', { path => 'notes/1' }), '/api/notes/1',
        'path is accepted and not checked against its routes');
    is($routing->path_for('/api/notes'), '/api/notes', 'its child still resolves');
};

subtest 'prefix parameters are required and validated' => sub {
    my $routing = _routing();
    like(dies { $routing->path_for('user') },
        qr/missing path parameter 'user_id' for route '\/user'/, 'a missing prefix parameter croaks');
    like(dies { $routing->path_for('user', { user_id => 'x' }) },
        qr/path parameter 'user_id' failed constraint for route '\/user'/, 'the inline constraint runs');
    is($routing->path_for('user', { user_id => 7 }), '/users/7', 'the prefix renders');
    is($routing->path_for('user', { user_id => 7, path => 'a' }), '/users/7/a',
        'and a path below it');
};

subtest 'an explicit constraint on a named Mount prefix' => sub {
    my $routing = router(routes => [
        mount('/u/{id}', app => $files, name => 'u', constraints => { id => qr/\A\d+\z/ }),
    ]);
    like(dies { $routing->path_for('u', { id => 'x' }) },
        qr/path parameter 'id' failed constraint for route '\/u'/, 'a bad value croaks');
    is($routing->path_for('u', { id => 7 }), '/u/7', 'a good value renders');
    is($routing->path_for('u', { id => 7, path => 'p/q' }), '/u/7/p/q', 'with a path below it');
};

subtest 'a Mount declared with a trailing slash' => sub {
    my $routing = router(routes => [mount('/static/', app => $files, name => 'static')]);
    is($routing->path_for('static'), '/static', 'the prefix has no trailing slash');
    is($routing->path_for('static', { path => 'a' }), '/static/a', 'and one slash before the path');
};

subtest 'a named Mount at the root' => sub {
    my $routing = router(routes => [mount('/', app => $files, name => 'site')]);
    is($routing->path_for('site'), '/', 'its prefix is /');
    is($routing->path_for('site', { path => 'x' }), '/x', 'a path below it');
};

subtest 'query and fragment follow the path' => sub {
    is(_routing()->path_for('static', { path => 'a.css' }, { v => 3 }, 'top'),
        '/static/a.css?v=3#top', 'compact form');
};

subtest 'the root and terminal navigation still croak' => sub {
    my $routing = _routing();
    for my $reference ('/', 'api/..', 'api/notes/..') {
        like(dies { $routing->path_for($reference) },
            qr/resolves to a logical namespace, not a route/, "$reference croaks");
    }
};

subtest 'scope-bound: path is never inherited, prefix parameters are' => sub {
    my $app = compose(routes => [
        mount('/files', routes => [
            route('/*path' => sub {
                my ($request) = @_;
                return response('JSON', { files => path_for($request, '../files') });
            }, name => 'file'),
        ], name => 'files'),
        mount('/u/{uid}', routes => [
            route('/' => sub {
                my ($request) = @_;
                return response('JSON', {
                    self  => path_for($request, '../u'),
                    below => path_for($request, '../u', { path => 'x' }),
                });
            }, name => 'index'),
        ], name => 'u'),
    ]);
    my $client = PAGI::Test::Client->new(app => $app);
    is($client->get('/files/deep/x.txt')->json, { files => '/files' },
        'a handler under a wildcard route does not pass its path on');
    is($client->get('/u/5/')->json, { self => '/u/5', below => '/u/5/x' },
        'a relative name inherits the prefix parameter');
};

subtest 'inside a routes Mount with a prefix parameter' => sub {
    my $resolver = PAGI::Routing::Resolver->new(routes => [
        mount('/api/{v}', routes => [
            route('/notes' => sub { }, name => 'notes'),
        ], name => 'api'),
    ]);
    my $in_api = _scope('http', $resolver, 'pagi.routing' => {
        version => 1,
        frames  => [_frame($resolver, logical_namespace => '/api', captures => { v => 2 })],
    });
    is(path_for($in_api, '../api'), '/api/2', 'a relative name inherits the prefix parameter');
    is(path_for($in_api, '../api', { path => 'x' }), '/api/2/x', 'and takes a path below it');
    like(dies { path_for($in_api, '/api') },
        qr/missing path parameter 'v' for route '\/api'/, 'an absolute name inherits nothing');
    like(dies { path_for($in_api, '.') },
        qr/resolves to a logical namespace, not a route/, 'a terminal dot still croaks');
};

subtest 'scope-bound: root_path and url_for' => sub {
    my $app = compose(routes => [
        route('/' => sub {
            my ($request) = @_;
            return response('JSON', {
                path => path_for($request, '/static', { path => 'a.css' }),
                url  => url_for($request, '/static', { path => 'a.css' }),
            });
        }, name => 'home'),
        mount('/static', app => $files, name => 'static'),
    ]);
    my $expected = {
        path => '/app/static/a.css',
        url  => 'http://testserver/app/static/a.css',
    };
    is(PAGI::Test::Client->new(app => $app, root_path => '/app')->get('/app/')->json,
        $expected, 'root_path is applied once');
    is(PAGI::Test::Client->new(app => compose(routes => [mount('/app', app => $app)]))
        ->get('/app/')->json, $expected, 'the same under an outer mount');

    my $resolver = PAGI::Routing::Resolver->new(routes => [
        mount('/static', app => $files, name => 'static'),
    ]);
    for my $case (
        ['websocket', 'wss',   'https://example.test/static/a.css'],
        ['websocket', 'ws',    'http://example.test/static/a.css'],
        ['sse',       'https', 'https://example.test/static/a.css'],
    ) {
        my ($type, $scheme, $url) = @$case;
        is(url_for(_scope($type, $resolver, scheme => $scheme), '/static', { path => 'a.css' }),
            $url, "a mount target from a $type $scheme scope is never ws/wss");
    }
};

subtest 'a route and a mount cannot share a name' => sub {
    my $clash = qr/\Aroute '\/x' and mount '\/api' both claim the name '\/api'; a name is one URL\. Put the landing route inside the mount as route\('\/'\)/;
    like(dies {
        router(routes => [
            route('/x' => sub { }, name => 'api'),
            mount('/api', app => $files, name => 'api'),
        ]);
    }, $clash, 'route then mount');
    like(dies {
        router(routes => [
            mount('/api', app => $files, name => 'api'),
            route('/x' => sub { }, name => 'api'),
        ]);
    }, $clash, 'mount then route');
    like(dies {
        router(routes => [
            mount('/v1', routes => [route('/x' => sub { }, name => 'api')]),
            mount('/api', app => $files, name => 'api'),
        ]);
    }, qr/\Aroute '\/v1\/x' and mount '\/api' both claim the name '\/api'/,
        'through an unnamed routes Mount');
};

subtest 'two mounts, or two routes, cannot share a name' => sub {
    like(dies {
        router(routes => [
            mount('/a', app => $files, name => 'dup'),
            mount('/b', app => $files, name => 'dup'),
        ]);
    }, qr/\Aduplicate canonical route address '\/dup' for effective paths '\/a' and '\/b'; add or change a local mount name/,
        'two mounts with one name');

    my $child = router(routes => [mount('/s', app => $files, name => 'static')]);
    like(dies {
        router(routes => [mount('/a', app => $child), mount('/b', app => $child)]);
    }, qr/\Aduplicate canonical route address '\/static' for effective paths '\/a\/s' and '\/b\/s'; add or change a local mount name/,
        'one child holding a named mount, placed twice under unnamed mounts');
    my $named = router(routes => [
        mount('/a', app => $child, name => 'a'),
        mount('/b', app => $child, name => 'b'),
    ]);
    is([sort keys %{$named->named_routes}], [qw(/a /a/static /b /b/static)],
        'named placements of the same child construct');

    like(dies {
        router(routes => [
            route('/a' => sub { }, name => 'show'),
            route('/b' => sub { }, name => 'show'),
        ]);
    }, qr/\Aduplicate canonical route address '\/show' for effective paths '\/a' and '\/b'; add or change a local mount name/,
        'two routes with one name (unchanged)');
};

subtest 'inspection lists named mounts' => sub {
    my $api = mount('/api', routes => [
        route('/notes' => sub { }, name => 'notes'),
    ], name => 'api');
    my $routing = router(routes => [
        route('/' => sub { }, name => 'home'),
        mount('/static', app => $files, name => 'static'),
        $api,
        mount('/users/{user_id:\d+}', routes => [
            route('/' => sub { }, name => 'index'),
        ], name => 'user'),
    ]);
    is([sort keys %{$routing->named_routes}],
        [qw(/api /api/notes /home /static /user /user/index)],
        'named_routes includes each named mount');
    is(refaddr($routing->route_named('/api')), refaddr($api),
        'route_named returns the declared Mount');
    isa_ok($routing->named_routes->{'/static'}, ['PAGI::Routing::Mount'],
        'named_routes maps a Mount address to its Mount');
    is($routing->_resolver->route_kind('/static'), 'mount', 'route_kind of a Mount address');
};

done_testing;
