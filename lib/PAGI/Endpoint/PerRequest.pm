package PAGI::Endpoint::PerRequest;

use strict;
use warnings;
use Future;
use Future::AsyncAwait;
use Carp qw(croak);
use Scalar::Util qw(blessed);
use PAGI::Request::_Factory ();
use PAGI::Utils qw(invoke_app);

sub new {
    my ($class, %args) = @_;
    return bless { class => $args{class}, build => $args{build} }, $class;
}

sub to_app {
    my ($self) = @_;
    my $class = $self->{class};
    my $build = $self->{build};

    return async sub {
        my ($scope, $receive, $send) = @_;
        my $request = PAGI::Request::_Factory::request_for_scope($scope, $receive);
        # A builder returns an app object, or a Future of one (an async builder).
        my $app = await Future->wrap($build->($request));
        croak "$class->BUILD_APP's builder must return an app object (one with to_app);"
            . ' a native PAGI application goes through as_app_object()'
            unless blessed($app) && $app->can('to_app');
        await invoke_app($app, $scope, $receive, $send);
    };
}

package PAGI::Endpoint::PerRequest::HTTP;

our @ISA = ('PAGI::Endpoint::PerRequest');

# Asked once by Route; answered by the class, which is never built for it.
sub allowed_methods {
    my ($self) = @_;
    return $self->{class}->allowed_methods;
}

1;

__END__

=head1 NAME

PAGI::Endpoint::PerRequest - The app object for an endpoint built per request

=head1 DESCRIPTION

When a class's C<BUILD_APP> returns a builder, C<endpoint('Class', %args)>
returns this app object for the route (L<PAGI::Endpoint>). It is not
constructed directly.

Its C<to_app> answers each request (each connection, for WebSocket and SSE)
by calling the builder with that request's L<PAGI::Request>, or the class
L<PAGI::Middleware::RequestClass> set, awaiting the result if the builder
returned a Future, and running the app object the builder returned. That
object lives until the request is answered or the connection ends. A builder
that returns no app object fails that request with "Class->BUILD_APP's
builder must return an app object (one with to_app); a native PAGI
application goes through as_app_object()".

C<PAGI::Endpoint::PerRequest::HTTP>, the wrapper for an HTTP class, also has
C<allowed_methods>, which asks the class, so the Route snapshots the class's
methods without building an object. The wrapper for a WebSocket or SSE class
has no C<allowed_methods>.

=head1 SEE ALSO

L<PAGI::Endpoint>

=cut
