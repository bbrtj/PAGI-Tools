use strict;
use warnings;
use Test2::V0;
use PAGI::Routing qw(route mount websocket sse);

# A framework wraps the constructors; the application imports the type.
{
    package Test::Framework;
    use PAGI::Routing qw(route mount);
    sub get_route { my ($path, $handler) = @_; route($path => $handler, declaration_package => scalar caller) }
    sub get_route_plain { my ($path, $handler) = @_; route($path => $handler) }
    sub at_mount { my ($path, @routes) = @_; mount($path, routes => \@routes, declaration_package => scalar caller) }
}
{
    package Test::App;
    use Types::Standard qw(Int);
    our $handler = sub { };
    our $direct  = eval { Test::Framework::get_route('/notes/{id:&Int}' => $handler) } || $@;
    our $plain   = eval { Test::Framework::get_route_plain('/notes/{id:&Int}' => $handler); 1 } ? 'lived' : $@;
    our $mounted = eval { Test::Framework::at_mount('/users/{id:&Int}', PAGI::Routing::route('/' => $handler)) } || $@;
}

isa_ok $Test::App::direct, ['PAGI::Routing::Route'], 'a wrapper forwards the application as the declaration package';
like $Test::App::plain,
    qr/inline constraint provider '&Int' for parameter 'id' is not defined in package 'Test::Framework'.*declaration_package/s,
    'without it, the croak names the package searched and the option that changes it';
isa_ok $Test::App::mounted, ['PAGI::Routing::Mount'], 'mount takes it too';

like dies { route('/x/{id:&Int}' => sub { }, declaration_package => 'not a package!') },
    qr/declaration_package must be a Perl package name/, 'it must be a package name';

ok lives { websocket('/ws/{id}' => sub { }, declaration_package => 'main') }, 'websocket accepts it';
ok lives { sse('/events/{id}' => sub { }, declaration_package => 'main') }, 'sse accepts it';

done_testing;
