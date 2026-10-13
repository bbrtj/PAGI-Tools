package PAGI::Request::_Factory;
use strict;
use warnings;

use Carp ();
use Scalar::Util ();
use PAGI::Request;

# The Request an application's code receives for this scope: the one the
# scope's 'pagi.request.factory' builds, set by middleware (see
# PAGI::Middleware::RequestClass), or a plain PAGI::Request when the key is
# absent or undef. The factory has request_response's request_factory
# contract: called with ($scope, $receive), synchronous, returns a
# PAGI::Request instance or subclass, and does not read the body.
sub request_for_scope {
    my ($scope, $receive) = @_;
    my $factory = $scope->{'pagi.request.factory'};
    return PAGI::Request->new($scope, $receive) unless defined $factory;
    Carp::croak("scope key 'pagi.request.factory' must be a coderef")
        unless ref($factory) eq 'CODE';
    my $request = $factory->($scope, $receive);
    Carp::croak("scope key 'pagi.request.factory' must return a PAGI::Request instance or subclass")
        unless Scalar::Util::blessed($request) && $request->isa('PAGI::Request');
    return $request;
}

1;
