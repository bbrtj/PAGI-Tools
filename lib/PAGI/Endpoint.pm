package PAGI::Endpoint;

use strict;
use warnings;
use Carp qw(croak);
use Scalar::Util qw(blessed);
use PAGI::Utils ();

sub new {
    my ($class, $endpoint_class, @args) = @_;
    croak 'endpoint expects a class name'
        unless defined $endpoint_class && !ref $endpoint_class && length $endpoint_class;
    croak 'endpoint arguments must be key/value pairs' if @args % 2;
    return bless { class => $endpoint_class, args => [@args] }, $class;
}

sub class { $_[0]->{class} }
sub args  { @{ $_[0]->{args} } }

sub endpoint {
    my ($self) = @_;
    $self->load_class;
    return $self->app_from($self->build);
}

sub load_class {
    my ($self) = @_;
    my $class = $self->class;
    # A package already defined (inline in app.pl, or loaded) is not
    # required: it may have no file.
    unless (PAGI::Utils::_package_is_defined($class)) {
        croak "invalid endpoint class name '$class'"
            unless $class =~ /\A[A-Za-z_]\w*(?:::[A-Za-z_]\w*)*\z/;
        (my $file = "$class.pm") =~ s{::}{/}g;
        eval { require $file; 1 } or do {
            # require's own "at FILE line N." would precede croak's.
            (my $error = $@) =~ s/ at \S+ line \d+\.\n\z//;
            croak "endpoint class $class could not be loaded: $error";
        };
    }
    croak "endpoint class $class has neither new nor BUILD_APP"
        unless $class->can('new') || $class->can('BUILD_APP');
    return;
}

sub build {
    my ($self) = @_;
    my $class = $self->class;
    return $class->can('BUILD_APP')
        ? $class->BUILD_APP($self->args)
        : $class->new($self->args);
}

sub app_from {
    my ($self, $built) = @_;
    return $built if blessed($built) && $built->can('to_app');

    my $class = $self->class;
    my $made_by = $class->can('BUILD_APP') ? "$class->BUILD_APP" : "$class->new";
    croak "$made_by must return an app object (one with to_app)";
}

1;

__END__

=head1 NAME

PAGI::Endpoint - Name an endpoint class at a route; the class decides how it is built

=head1 SYNOPSIS

    use PAGI::Tools qw(compose endpoint mount route websocket);

    compose(routes => [
        route('/notes'     => endpoint('MyApp::Notes', page_size => 50)),
        websocket('/watch' => endpoint('MyApp::Watch', greeting => 'welcome')),
        mount('/health', app => endpoint('MyApp::Health', version => '1.0')),
    ]);

=head1 DESCRIPTION

C<endpoint('Class', %args)>, exported by L<PAGI::Routing> and L<PAGI::Tools>,
names an endpoint class at a C<route>, C<websocket>, C<sse> or C<mount>. It
loads the class by its exact package name and lets the class decide how it is
built:

    The class                          Built                     Answers
    ---------------------------------  ------------------------  ----------------------
    no BUILD_APP                       once, Class->new(%args),  every request and
                                       when endpoint() runs      connection, concurrently
    BUILD_APP returns an app object    once, when endpoint()     every request and
                                       runs                      connection, concurrently

An app object is any object with a C<to_app> method: an Endpoint, a
L<PAGI::Response>, a Router. The framework only ever calls the class's own
C<new> or C<BUILD_APP>, so a Moo class with C<required> attributes works.
Handlers receive the request or connection as an argument; it is never stored
on the object.

A class declared in the application file itself is used as it is, with no
file to load. An instance placed by hand, C<< route('/x' => Class->new(%args)) >>,
still works: it is the first row without the loading.

=head1 BUILD_APP

    sub BUILD_APP {
        my ($class, %args) = @_;
        return $class->new(%args, started => time);
    }

C<BUILD_APP> is called once, as a class method, with C<endpoint>'s arguments,
in place of C<new>. The app object it returns is placed at the route as it is
and answers every request. It need not be an instance of the class.

=head1 LIFETIMES AND LIFESPAN

C<endpoint()> runs when the application file is loaded, before lifespan
startup. An object built then cannot be given anything startup builds as a
constructor argument: reach those services at request time through
C<< $request->state >>, C<< $websocket->state >> or C<< $sse->state >>.

An object built once lives as long as the application and serves concurrent
requests, so keep only configuration and long-lived services on it, and
per-request state on the Request, WebSocket or SSE object. Its state is per
worker process: C<pagi-server --workers 4> builds four.

=head1 WHEN THINGS FAIL

Each of these dies at the C<endpoint()> call, while the application file
loads.

    Mistake                                 Message
    --------------------------------------  ----------------------------------------
    no class name                           endpoint expects a class name
    an odd argument list                    endpoint arguments must be key/value pairs
    not a package name ('Bad Name')         invalid endpoint class name 'Bad Name'
    an unknown class, or its file does      endpoint class X could not be loaded: ...
    not compile
    a class with neither new nor BUILD_APP  endpoint class X has neither new nor BUILD_APP
    a required attribute is missing         the class's own error (Moo: Missing
                                            required arguments: ...)
    BUILD_APP or new returns no app object  X->BUILD_APP must return an app object
                                            (one with to_app)

A misspelt class name that compiled code already uses as a package, as in
C<Misspelt::Name::helper()>, reads as defined and is not required, so it dies
"has neither new nor BUILD_APP" rather than "could not be loaded".

=head1 METHODS

PAGI::Endpoint is a plain class. C<endpoint> runs its steps in order, and each
step is a public method, so a framework can subclass PAGI::Endpoint, override
one step, and export its own C<endpoint>:

    package MyFramework;
    sub endpoint { MyFramework::Endpoint->new(@_)->endpoint }

=head2 new

    my $endpoint = PAGI::Endpoint->new($class, %args);

Records the class name and its arguments; it loads and builds nothing. It dies
"endpoint expects a class name" without a class name, and "endpoint arguments
must be key/value pairs" for an odd argument list.

=head2 class

The class name given to C<new>.

=head2 args

The arguments given to C<new>, as a list, unchanged and in order.

=head2 endpoint

    my $app_object = $endpoint->endpoint;

Runs C<load_class>, then C<app_from> on what C<build> returns, and returns
the app object for a route or mount. C<endpoint('Class', %args)> in
L<PAGI::Routing> is C<< PAGI::Endpoint->new('Class', %args)->endpoint >>.

=head2 load_class

Loads the class by its exact package name, unless the package is already
defined (declared in the application file, or loaded before), which needs no
file. It then checks that the class has C<new> or C<BUILD_APP>. A subclass may
override it; calling C<< $self->SUPER::load_class >> keeps the checks.

=head2 build

Calls C<< Class->BUILD_APP(%args) >> if the class has one, otherwise
C<< Class->new(%args) >>, and returns what it returns. A subclass may
override it.

=head2 app_from

    my $app_object = $endpoint->app_from($built);

Turns what C<build> returned into the route's app object: an object with
C<to_app> is used as it is. Anything else dies "Class->BUILD_APP must return
an app object (one with to_app)", or "Class->new must ..." for a class without
C<BUILD_APP>. A subclass may override it.

=head1 SEE ALSO

L<PAGI::Routing/endpoint>, L<PAGI::Endpoint::HTTP>,
L<PAGI::Endpoint::WebSocket>, L<PAGI::Endpoint::SSE>

=cut
