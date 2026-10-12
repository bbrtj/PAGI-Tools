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
    return $self->per_request_app($built) if ref($built) eq 'CODE';

    my $class = $self->class;
    my $made_by = $class->can('BUILD_APP') ? "$class->BUILD_APP" : "$class->new";
    croak "$made_by must return an app object (one with to_app)"
        . ' or a coderef that builds one per request';
}

sub per_request_app {
    my ($self, $builder) = @_;
    require PAGI::Endpoint::PerRequest;
    my $wrapper = $self->class->can('allowed_methods')
        ? 'PAGI::Endpoint::PerRequest::HTTP'
        : 'PAGI::Endpoint::PerRequest';
    return $wrapper->new(class => $self->class, build => $builder);
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

    # A Moo class that wants a fresh object for every request.
    package MyApp::Notes;
    use Moo;
    use Future::AsyncAwait;
    use PAGI::Tools qw(response);
    extends 'PAGI::Endpoint::HTTP';

    has page_size    => (is => 'ro', default => 20);
    has current_user => (is => 'ro', required => 1);

    sub BUILD_APP {
        my ($class, %args) = @_;
        return sub {
            my ($request) = @_;
            return $class->new(%args,
                current_user => $request->header('X-User') // 'anonymous');
        };
    }

    async sub get {
        my ($self, $request) = @_;
        return response('JSON', { user => $self->current_user });
    }

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
    BUILD_APP returns a builder        the builder once; its     that request or
                                       app object per request    connection only
                                       or connection

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
        return $class->new(%args, started => time);   # an app object
    }

C<BUILD_APP> is called once, as a class method, with C<endpoint>'s arguments,
in place of C<new>. What it returns decides the lifecycle:

=over 4

=item * An app object (one with C<to_app>) is placed at the route as it is and
answers every request. It need not be an instance of the class.

=item * A coderef is a builder. It is called with a L<PAGI::Request> for every
request (every connection, for WebSocket and SSE) and returns the app object
that answers it. It may return any app object, including a Response that
refuses the request:

    sub BUILD_APP {
        my ($class, %args) = @_;
        return sub {
            my ($request) = @_;
            return response('Text', 'no token', status => 403)
                unless $request->header('X-Token');
            return $class->new(%args);
        };
    }

=item * A builder may be async: it returns an app object, or a Future of one.
The typical async builder fills a C<required> attribute from I/O:

    sub BUILD_APP {
        my ($class, %args) = @_;
        return async sub {
            my ($request) = @_;
            my $user = await $args{users}->find($request->header('X-User-Id'));
            return response('Text', 'who?', status => 401) unless $user;
            return $class->new(%args, current_user => $user);
        };
    }

A builder that dies, or whose Future fails, fails that request like a dying
handler: a 500, with the error re-raised to the server.

=back

A coderef from C<BUILD_APP> is always a builder. A native PAGI application,
C<async sub { my ($scope, $receive, $send) = @_; ... }>, returned there is not
supported: it is called as a builder, with one argument. Return
C<as_app_object($app)> (L<PAGI::Utils>) instead.

=head1 WHAT THE BUILDER RECEIVES

The builder receives a L<PAGI::Request> for HTTP, WebSocket and SSE alike, or
the class L<PAGI::Middleware::RequestClass> set. For WebSocket and SSE it is
not the connection helper: the object the builder returns accepts, sends and
closes.

The builder reads what the request already carries: headers, cookies, query
and path parameters, and state. It should not read the body, nor C<receive>
on a WebSocket or SSE scope, because the endpoint it builds owns that input;
this is not enforced. A builder that awaits the body
(C<< await $request->json >>) consumes it: the handler still gets C<json>,
C<form> and C<body> from the scope's cache, but C<body_stream> then dies
"Body already consumed".

The handler's C<$request> is not the builder's object. An HTTP endpoint makes
its own Request for its method, and both read the same cached headers,
cookies and body; a Request class's C<new> therefore runs twice for that
request.

=head1 METHODS AND 405

An HTTP endpoint tells its Route which methods it answers through
C<allowed_methods> (L<PAGI::Endpoint::HTTP>). For a class built per request
the Route asks the class, which is never built for it, so such a class that
overrides C<allowed_methods> must answer it as a class method.

At a plain route the Router answers a method the class does not advertise,
with its 405 and C<Allow>, before anything is built: the builder never sees
that method. Mounted, or routed with C<< methods => '*' >>, nothing filters
first: the builder runs for every method, and the object it builds answers an
unadvertised one with its C<method_not_allowed> (or the builder's own refusal
answers first). OPTIONS reaches the endpoint, which answers 204 with
C<Allow>.

=head1 LIFETIMES AND LIFESPAN

C<endpoint()> runs when the application file is loaded, before lifespan
startup. An object built then cannot be given anything startup builds as a
constructor argument: reach those services at request time through
C<< $request->state >>, C<< $websocket->state >> or C<< $sse->state >>.

An object built once lives as long as the application and serves concurrent
requests, so keep only configuration and long-lived services on it, and
per-request state on the Request, WebSocket or SSE object. Its state is per
worker process: C<pagi-server --workers 4> builds four.

An object a builder returns lives until its request is answered, or for
WebSocket and SSE until its connection ends, so it may keep that request's
or connection's state on C<$self>.

=head1 WHEN THINGS FAIL

"Load" is the C<endpoint()> call, while the application file loads. "First
request" is a 500 for that request, with the error re-raised to the server.

    Mistake                                 When           Message
    --------------------------------------  -------------  ------------------------------
    no class name                           load           endpoint expects a class name
    an odd argument list                    load           endpoint arguments must be
                                                           key/value pairs
    not a package name ('Bad Name')         load           invalid endpoint class name
                                                           'Bad Name'
    an unknown class, or its file does      load           endpoint class X could not be
    not compile                                            loaded: ...
    a class with neither new nor BUILD_APP  load           endpoint class X has neither
                                                           new nor BUILD_APP
    a singleton's required attribute is     load           the class's own error (Moo:
    missing                                                Missing required arguments: ...)
    BUILD_APP or new returns neither an     load           X->BUILD_APP must return an app
    app object nor a coderef                               object (one with to_app) or a
                                                           coderef that builds one per
                                                           request
    the builder dies, or its Future fails   first request  the builder's error
    the builder returns no app object       first request  X->BUILD_APP's builder must
                                                           return an app object (one with
                                                           to_app); a native PAGI
                                                           application goes through
                                                           as_app_object()

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
C<to_app> is used as it is, and a coderef goes to C<per_request_app>.
Anything else dies "Class->BUILD_APP must return an app object (one with
to_app) or a coderef that builds one per request", or "Class->new must ..."
for a class without C<BUILD_APP>. A subclass may override it.

=head2 per_request_app

    my $app_object = $endpoint->per_request_app($builder);

Returns the app object that calls the builder for each request or connection
(L<PAGI::Endpoint::PerRequest>). For an HTTP class, one with
C<allowed_methods>, the app object answers C<allowed_methods> by asking the
class. A subclass may override it.

=head1 SEE ALSO

L<PAGI::Routing/endpoint>, L<PAGI::Endpoint::PerRequest>,
L<PAGI::Endpoint::HTTP>, L<PAGI::Endpoint::WebSocket>,
L<PAGI::Endpoint::SSE>

=cut
