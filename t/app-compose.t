use strict;
use warnings;
use Test2::V0;
use File::Temp qw(tempdir);
use Scalar::Util qw(refaddr);
use Future;
use Future::AsyncAwait;
use lib 'lib';
use PAGI::App::Compose;
use PAGI::Test::Client;
use PAGI::Tools qw(middleware response route);

# Run run() with STDOUT and STDERR captured.
sub run_cli {
    my ($app, @args) = @_;
    my ($out, $err) = ('', '');
    open my $o, '>', \$out or die; open my $e, '>', \$err or die;
    my $status = do { local *STDOUT = $o; local *STDERR = $e; $app->run(@args) };
    return ($status, $out, $err);
}

our @ORDER;
our $ROUTES_BUILT = 0;

package Local::Hello {
    use parent -norequire, 'PAGI::App::Compose';
    use PAGI::Tools qw(response route);
    sub routes { $main::ROUTES_BUILT++; [ route('/' => sub { response('Text', 'hello') }, name => 'home') ] }
}
package Local::Full {
    use parent -norequire, 'PAGI::App::Compose';
    use PAGI::Tools qw(app_state middleware response route);
    sub prepare_app    { push @main::ORDER, 'prepare_app' }
    sub routes         { push @main::ORDER, 'routes';
                         [ route('/db' => sub { response('Text', app_state($_[0])->get('db')) }) ] }
    sub app_middleware { push @main::ORDER, 'app_middleware'; [ middleware('RequestId') ] }
    sub http_default   { push @main::ORDER, 'http_default';
                         sub { response('Text', 'custom miss', status => 404) } }
    sub on_startup     { my ($self, $state) = @_; $state->{db} = 'connected' }
    sub on_shutdown    { $main::SHUT = 1 }
}
package Local::StartOnly    { use parent -norequire, 'Local::Hello'; sub on_startup  { $_[1]{a} = 1 } }
package Local::ShutOnly     { use parent -norequire, 'Local::Hello'; sub on_shutdown { 1 } }
package Local::Leaf         { use parent -norequire, 'Local::StartOnly' }
package Local::Layered      { use parent -norequire, 'Local::StartOnly';
                              sub on_startup { my ($self, $s) = @_; $self->SUPER::on_startup($s); $s->{b} = 2 } }
package Local::AsyncStart   { use parent -norequire, 'Local::Hello'; use Future::AsyncAwait;
                              async sub on_startup { my ($self, $s) = @_; await Future->done; $s->{async} = 1 } }
package Local::DyingStart   { use parent -norequire, 'Local::Hello'; sub on_startup { die "hook broke\n" } }
package Local::DyingStop    { use parent -norequire, 'Local::Hello'; sub on_shutdown { die "shutdown broke\n" } }
package Local::WithCall     { use parent -norequire, 'Local::Hello'; sub call { } }
package Local::NoRoutes     { use parent -norequire, 'PAGI::App::Compose' }
package Local::ListRoutes   { use parent -norequire, 'PAGI::App::Compose'; use PAGI::Tools qw(response route);
                              sub routes { (route('/a' => sub { response('Text', 'a') }), route('/b' => sub { response('Text', 'b') })) } }
package Local::ListMw       { use parent -norequire, 'Local::Hello'; use PAGI::Tools qw(middleware);
                              sub app_middleware { (middleware('RequestId'), middleware('RequestId')) } }
package Local::MissingMw    { use parent -norequire, 'Local::Hello'; use PAGI::Tools qw(middleware);
                              sub app_middleware { [ middleware('Does::Not::Exist') ] } }
package Local::AllImports   { use parent -norequire, 'PAGI::App::Compose'; use PAGI::Tools qw(:all);
                              sub routes { [ route('/' => sub { response('Text', 'all') }) ] } }
package main;

our $SHUT = 0;

subtest 'a routes-only class: no lifespan, served without state' => sub {
    my $app = Local::Hello->new;
    isa_ok $app->composition, 'PAGI::Compose';
    is $app->composition->lifespan, undef, 'no lifespan';
    is(PAGI::Test::Client->new(app => $app)->get('/')->text, 'hello', 'answers under lifespan => 0');
};

subtest 'the hooks run at to_app, never per request' => sub {
    $ROUTES_BUILT = 0;
    my $client = PAGI::Test::Client->new(app => Local::Hello->new);
    $client->get('/') for 1 .. 3;
    is $ROUTES_BUILT, 1, 'routes ran once for three requests';
};

subtest 'every hook, in order' => sub {
    @ORDER = ();
    $SHUT = 0;
    PAGI::Test::Client->run(Local::Full->new, sub {
        my ($client) = @_;
        my $r = $client->get('/db');
        is $r->text, 'connected', 'on_startup state reaches the handler';
        ok $r->header('X-Request-ID'), 'app_middleware applied';
        my $miss = $client->get('/nowhere');
        is [$miss->status, $miss->text], [404, 'custom miss'], 'http_default answers a miss';
    });
    is $SHUT, 1, 'on_shutdown ran';
    is \@ORDER, [qw(prepare_app routes app_middleware http_default)], 'prepare_app, then the hooks in order';
};

subtest 'lifespan only for overridden hooks' => sub {
    is [sort keys %{ Local::StartOnly->new->composition->lifespan }], ['startup'], 'on_startup only';
    is [sort keys %{ Local::ShutOnly->new->composition->lifespan }],  ['shutdown'], 'on_shutdown only';
    is [sort keys %{ Local::Leaf->new->composition->lifespan }],      ['startup'], 'inherited from an intermediate base';
    my $state;
    PAGI::Test::Client->run(Local::Layered->new, sub { $state = $_[0]->state });
    is [$state->{a}, $state->{b}], [1, 2], 'SUPER::on_startup layers';
    PAGI::Test::Client->run(Local::AsyncStart->new, sub { $state = $_[0]->state });
    is $state->{async}, 1, 'an async on_startup is awaited';
};

subtest 'mistakes croak naming the fix' => sub {
    like dies { Local::WithCall->new->to_app },      qr/is a PAGI::App::Compose: .*remove call/, 'call, at to_app';
    like dies { Local::WithCall->new->composition }, qr/remove call/, 'call, at composition';
    like dies { Local::NoRoutes->new->to_app },      qr/Local::NoRoutes must implement routes/, 'no routes';
    like dies { Local::ListRoutes->new->to_app },    qr/Local::ListRoutes->routes must return an arrayref/, 'routes as a list';
    like dies { Local::ListMw->new->to_app },        qr/Local::ListMw->app_middleware must return an arrayref/, 'app_middleware as a list';
};

subtest 'composition: inspected without compiling, fresh each call' => sub {
    my $app = Local::MissingMw->new;
    my $composition = $app->composition;
    is $composition->path_for('/home'), '/', 'path_for';
    is [keys %{ $composition->named_routes }], ['/home'], 'named_routes';
    like dies { $app->to_app }, qr/Does::Not::Exist/, 'middleware is loaded only by to_app';
    $ROUTES_BUILT = 0;
    my $hello = Local::Hello->new;
    isnt refaddr($hello->composition), refaddr($hello->composition), 'two calls, two descriptions';
    is $ROUTES_BUILT, 2, 'and the hooks ran twice';
    my ($one, $two) = ($hello->to_app, $hello->to_app);
    isnt refaddr($one), refaddr($two), 'served twice: two applications';
};

subtest 'PAGI::Tools :all shadows no hook' => sub {
    is(PAGI::Test::Client->new(app => Local::AllImports->new)->get('/')->text, 'all');
};

subtest 'Moo' => sub {
    skip_all 'Moo required' unless eval { require Moo; require Moo::Role; 1 };
    eval q{
        package Local::MooRole { use Moo::Role; use PAGI::Tools qw(middleware);
            around app_middleware => sub { my ($orig, $self) = @_; [ middleware('RequestId'), @{ $self->$orig } ] };
            after on_startup => sub { $_[1]{from_role} = 1 } }
        package Local::MooSupplies { use Moo::Role; sub on_shutdown { $main::SHUT = 'role' } }
        package Local::MooApp { use Moo; extends 'PAGI::App::Compose';
            use PAGI::Tools qw(response route);
            has greeting => (is => 'ro', default => sub { 'hi' });
            sub routes { my $g = $_[0]->greeting; [ route('/' => sub { response('Text', $g) }) ] }
            with 'Local::MooRole', 'Local::MooSupplies' }
        package Local::MooLazy { use Moo; extends 'PAGI::App::Compose';
            use PAGI::Tools qw(response route);
            has routes => (is => 'lazy');
            sub _build_routes { [ route('/' => sub { response('Text', 'lazy') }) ] } }
        1;
    } or die $@;
    $SHUT = 0;
    my ($r, $state);
    PAGI::Test::Client->run(Local::MooApp->new, sub { $r = $_[0]->get('/'); $state = $_[0]->state });
    is $r->text, 'hi', 'an attribute default read in routes';
    ok $r->header('X-Request-ID'), 'a role around app_middleware';
    is $state->{from_role}, 1, 'a role after on_startup installs lifespan';
    is $SHUT, 'role', 'a role supplying on_shutdown as a method';
    is(PAGI::Test::Client->new(app => Local::MooLazy->new)->get('/')->text, 'lazy', 'routes as a lazy attribute');
};

subtest 'Moose with MooseX::NonMoose' => sub {
    skip_all 'Moose and MooseX::NonMoose required'
        unless eval { require Moose; require MooseX::NonMoose; 1 };
    eval q{
        package Local::MooseApp { use Moose; use MooseX::NonMoose; extends 'PAGI::App::Compose';
            use PAGI::Tools qw(response route);
            has greeting => (is => 'ro', default => 'moose');
            sub routes { my $g = $_[0]->greeting; [ route('/' => sub { response('Text', $g) }) ] }
            sub on_startup { $_[1]{moose} = 1 }
            __PACKAGE__->meta->make_immutable }
        1;
    } or die $@;
    my ($text, $state);
    PAGI::Test::Client->run(Local::MooseApp->new, sub { $text = $_[0]->get('/')->text; $state = $_[0]->state });
    is [$text, $state->{moose}], ['moose', 1];
};

subtest 'run_if_script and the command line' => sub {
    my $dir = tempdir(CLEANUP => 1);
    mkdir "$dir/Local" or die $!;
    open my $fh, '>', "$dir/Local/Script.pm" or die $!;
    print $fh <<'PM';
package Local::Script;
use strict;
use warnings;
use parent 'PAGI::App::Compose';
use PAGI::Tools qw(response route);
sub routes { [ route('/' => sub { response('Text', 'script') }) ] }
__PACKAGE__->run_if_script;
PM
    close $fh;
    my $provider = do "$dir/Local/Script.pm" or die $@ || $!;
    ok !$provider->isa('Local::Script'), 'loaded by path: a provider';
    is(PAGI::Test::Client->new(app => $provider)->get('/')->text, 'script', 'that builds when asked');
    my ($status, $out) = run_cli(Local::Hello->new, '/');
    is [$status, $out], [0, 'hello'], 'the command line runs one request';
    ($status, undef, my $err) = run_cli(Local::DyingStart->new, '/');
    is $status, 1, 'a dying on_startup exits 1';
    like $err, qr/hook broke/, 'with its message';
    ($status, $out, $err) = run_cli(Local::DyingStop->new, '/');
    is [$status, $out], [1, 'hello'], 'a dying on_shutdown exits 1, the response still printed';
    like $err, qr{\AHTTP/1\.1 200\n.*shutdown broke}s, 'the status, then the shutdown error';
};

done_testing;
