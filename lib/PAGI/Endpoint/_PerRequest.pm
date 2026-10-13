package PAGI::Endpoint::_PerRequest;

# The app object endpoint('Class') returns when the class's BUILD_APP returns
# a builder (PAGI::Endpoint per_request_app). Each request, or each WebSocket
# or SSE connection, gets the Request (the class RequestClass set, or a plain
# PAGI::Request), the builder's app object built from it, and that object run.
# Internal: not constructed directly, not public API.

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

package PAGI::Endpoint::_PerRequest::HTTP;

# The wrapper for an HTTP class. A WebSocket or SSE route never asks for
# allowed_methods, so only this one has it.
our @ISA = ('PAGI::Endpoint::_PerRequest');

# Asked once by Route; answered by the class, which is never built for it.
sub allowed_methods {
    my ($self) = @_;
    return $self->{class}->allowed_methods;
}

1;
