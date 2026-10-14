use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(blessed refaddr weaken);
use lib 'lib';
use PAGI::State qw(app_state singleton per_request factory);
use PAGI::Request;

my $no_body = sub { Future->done({ type => 'http.request', body => '', more => 0 }) };

# A request scope as the server builds one: its own shallow copy of the
# worker's state.
sub request_scope {
    my ($worker) = @_;
    return { type => 'http', method => 'GET', path => '/', headers => [], state => { %$worker } };
}
sub view { app_state(request_scope(@_)) }

subtest 'singleton: built on first get, once, through the view' => sub {
    my $built = 0;
    my %worker = (
        dsn   => 'db:x',
        store => singleton { my ($s) = @_; $built++; { db => $s->get('db') } },
        db    => singleton { my ($s) = @_; 'conn(' . $s->get('dsn') . ')' },
    );
    is $built, 0, 'not built at declaration';
    my $first = view(\%worker)->get('store');
    is $first, { db => 'conn(db:x)' }, 'built through the view, dependencies in any order';
    is refaddr(view(\%worker)->get('store')), refaddr($first), 'the same value for the next request';
    is $built, 1, 'built once';
};

subtest 'a singleton whose builder dies keeps nothing' => sub {
    my $tries = 0;
    my %worker = (x => singleton { die "no\n" if ++$tries == 1; 'ok' });
    like dies { view(\%worker)->get('x') }, qr/^no$/, 'the first get dies';
    ok !$worker{x}->built, 'nothing kept';
    is view(\%worker)->get('x'), 'ok', 'the next get builds again';
};

subtest 'built and value' => sub {
    my %worker = (x => singleton { 'v' });
    ok !$worker{x}->built, 'not built';
    like dies { $worker{x}->value }, qr/has not been built/, 'value dies before';
    view(\%worker)->get('x');
    is [$worker{x}->built, $worker{x}->value], [1, 'v'], 'built, and its value';
};

subtest 'per_request: once per request, shared by its views, given the source' => sub {
    my (@sources, $built);
    my %worker = (who => per_request { my ($s, $source) = @_; push @sources, blessed($source) ? ref $source : 'SCOPE'; ++$built });
    my $scope = request_scope(\%worker);
    my $from_middleware = app_state($scope)->get('who');
    my $inner = { %$scope, extra => 1 };    # a middleware's modify_scope copy
    my $from_handler = PAGI::Request->new($inner, $no_body)->state->get('who');
    is [$from_middleware, $from_handler], [1, 1], 'one build for the request, every view';
    is \@sources, ['SCOPE'], "the first asker's source: the scope, for app_state(\$scope)";
    is(PAGI::Request->new(request_scope(\%worker), $no_body)->state->get('who'), 2,
        'rebuilt for the next request');
    is $sources[-1], 'PAGI::Request', 'a Request for $request->state';
};

subtest 'per_request outside a request croaks' => sub {
    my %worker = (who => per_request { 1 });
    like dies { app_state({ type => 'lifespan', state => \%worker })->get('who') },
        qr/outside a request/;
};

subtest 'factory: built on every get, given the source' => sub {
    my $n = 0;
    my %worker = (f => factory { my ($s, $source) = @_; [++$n, ref $source] });
    my $request = PAGI::Request->new(request_scope(\%worker), $no_body);
    is [$request->state->get('f'), $request->state->get('f')],
        [[1, 'PAGI::Request'], [2, 'PAGI::Request']];
};

subtest 'a cycle croaks naming the chain' => sub {
    my %worker = (a => singleton { $_[0]->get('b') }, b => singleton { $_[0]->get('a') });
    like dies { view(\%worker)->get('a') }, qr/State key cycle: a -> b -> a/;
    ok !$worker{a}->built && !$worker{b}->built, 'nothing kept';
};

subtest 'a singleton cannot keep a per_request value' => sub {
    my %worker = (
        who  => per_request { 'someone' },
        keep => singleton { $_[0]->get('who') },
        fact => factory { my ($s, $source) = @_; defined $source ? 'had source' : 'no source' },
        uses => singleton { $_[0]->get('fact') },
    );
    like dies { view(\%worker)->get('keep') }, qr/while building a singleton/;
    is view(\%worker)->get('uses'), 'no source', 'a factory asked for by a singleton gets no source';
};

subtest 'async singleton: one build shared by its waiters' => sub {
    my ($builds, $build) = (0);
    my %worker = (db => singleton { $builds++; $build = Future->new });
    my $one = view(\%worker)->get('db');
    my $two = view(\%worker)->get('db');
    isa_ok $one, ['Future'], 'get on an async key is a Future';
    is $builds, 1, 'one build';
    ok !$one->is_ready && !$two->is_ready, 'both pending';
    $build->done('conn');
    is [$one->get, $two->get], ['conn', 'conn'], 'both resolve to the value';
    is refaddr(view(\%worker)->get('db')), refaddr($build), 'a done build is handed out as is';
};

subtest 'async singleton: a failed build is not kept' => sub {
    my @builds;
    my %worker = (db => singleton { push @builds, Future->new; $builds[-1] });
    my ($one, $two) = map { view(\%worker)->get('db') } 1, 2;
    $builds[0]->fail("refused\n");
    is [map { scalar $_->failure } $one, $two], ["refused\n", "refused\n"], 'every waiter gets the failure';
    ok !$worker{db}->built, 'nothing kept';
    my $three = view(\%worker)->get('db');
    is scalar @builds, 2, 'the next get builds again';
    $builds[1]->done('conn');
    is $three->get, 'conn', 'and succeeds';
};

subtest 'a caller that goes away cancels only its own Future, with no warning' => sub {
    my @warnings;
    {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        my $build;
        my %worker = (db => singleton { $build = Future->new });
        my $gone  = (async sub { await view(\%worker)->get('db') })->();
        my $stays = view(\%worker)->get('db');
        $gone->cancel;
        ok !$build->is_ready, 'the build is still running';
        $build->done('conn');
        is $stays->get, 'conn', 'the other waiter gets it';

        my $alone;
        my %again = (db => singleton { $alone = Future->new });
        $_->cancel for map { view(\%again)->get('db') } 1, 2;
        ok !$alone->is_ready && $again{db}->built, 'every waiter gone: the build runs on, kept';
        $alone->done('later');
        is view(\%again)->get('db')->get, 'later', 'and is there for the next get';
    }
    is \@warnings, [], 'no warning (Future::XS when installed)';
};

subtest 'a cancelled build is dropped' => sub {
    my @builds;
    my %worker = (db => singleton { push @builds, Future->new; $builds[-1] });
    my $waiter = view(\%worker)->get('db');
    $builds[0]->cancel;
    like scalar $waiter->failure, qr/the build of state key 'db' was cancelled/, 'its waiter fails, naming the key';
    ok !$worker{db}->built, 'nothing kept';
    view(\%worker)->get('db');
    is scalar @builds, 2, 'the next get builds again';
};

subtest 'a pending per_request build is freed with its request' => sub {
    my $build;
    my %worker = (who => per_request { $build = Future->new });
    my $scope  = request_scope(\%worker);
    my $waiter = app_state($scope)->get('who');
    weaken(my $weak = $build);
    undef $build;
    undef $waiter;
    undef $scope;
    ok !defined $weak, 'the build is freed with the request state copy';
};

subtest 'async per_request: one build per request' => sub {
    my $builds = 0;
    my %worker = (who => per_request { $builds++; Future->done("visitor $builds") });
    my $scope = request_scope(\%worker);
    is [map { app_state($scope)->get('who')->get } 1, 2], ['visitor 1', 'visitor 1'],
        'the middleware and the handler share one build';
    is app_state(request_scope(\%worker))->get('who')->get, 'visitor 2', 'a new one for the next request';
};

subtest 'a cycle through async builders fails the awaited Future' => sub {
    my %worker = (
        a => (singleton async sub { my ($s) = @_; await $s->get('b') }),
        b => (singleton async sub { my ($s) = @_; await Future->done; await $s->get('a') }),
    );
    like scalar view(\%worker)->get('a')->failure, qr/State key cycle: a -> b -> a/;
};

subtest 'async factory: a build per get' => sub {
    my $n = 0;
    my %worker = (f => factory async sub { ++$n });
    my $view = view(\%worker);
    is [$view->get('f')->get, $view->get('f')->get], [1, 2];
};

subtest 'reserved keys stay hidden; data is raw' => sub {
    my %worker = (who => per_request { 1 }, plain => 'p');
    my $view = app_state(request_scope(\%worker));
    $view->get('who');
    is [sort $view->keys], ['plain', 'who'], 'keys';
    ok !$view->exists('pagi.state.per_request'), 'exists';
    my $error = dies { $view->get('nope') };
    like $error, qr/Available keys: plain, who\b/, 'the absent-key list';
    unlike $error, qr/pagi\.state/, 'without the reserved key';
    isa_ok $view->data->{who}, ['PAGI::State::Deferred'], 'data is raw';
    is $view->get('who', 'default'), 1, 'two-argument get resolves a declared key';
};

subtest 'a Deferred subclass with its own resolve' => sub {
    { package Local::Constant; our @ISA = ('PAGI::State::Deferred'); sub resolve { 'from subclass' } }
    my %worker = (x => Local::Constant->new(sub { }));
    is view(\%worker)->get('x'), 'from subclass';
};

subtest 'per_request on a WebSocket is one value for the connection' => sub {
    my $n = 0;
    my %worker = (who => per_request { ++$n });
    my $connection = { type => 'websocket', path => '/', headers => [], state => { %worker } };
    is [map { app_state($connection)->get('who') } 1 .. 3], [1, 1, 1];
};

subtest "value on a pending build is the caller's own Future" => sub {
    my $build;
    my %worker = (db => singleton { $build = Future->new });
    view(\%worker)->get('db');
    my $mine = $worker{db}->value;
    $mine->cancel;
    ok !$build->is_ready, 'cancelling it leaves the build';
    $build->done(1);
};

done_testing;
