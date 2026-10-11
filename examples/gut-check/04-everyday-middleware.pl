#!/usr/bin/env perl
#
# Two everyday middlewares, written as plain functions (app in, app out):
# a Server-Timing header and a maintenance switch. 04b-bundled-middleware.pl
# does the same jobs with middleware Tools ships.
#
# PAGI middleware sees protocol events, not a response object, so headers are
# edited on the way out with wrap_response_headers. Short-circuiting is easy
# because a response is itself an application: answer with it directly.
#
# The Starlette version is in README.md.
#
# Run:  pagi-server --app examples/gut-check/04-everyday-middleware.pl --port 5000
# Try:  curl -i localhost:5000/
#       MAINTENANCE=1 pagi-server ...; curl -i localhost:5000/   (503)
#       curl -i localhost:5000/health                            (always 200)

use v5.40;
use Future::AsyncAwait;
use Time::HiRes qw(time);
use PAGI::Tools qw(compose middleware response route wrap_response_headers);

# Server-Timing: how long the application took to start its response.
sub timing ($app) {
    return async sub ($scope, $receive, $send) {
        my $started = time;
        my $timed_send = wrap_response_headers($send, sub ($headers, $event) {
            $headers->set('Server-Timing', sprintf('app;dur=%.1f', 1000 * (time - $started)));
        });
        return await $app->($scope, $receive, $timed_send);
    };
}

# Maintenance mode: every HTTP request but /health gets a 503 page.
my $back_soon = response('Text', 'back soon', status => 503, headers => ['Retry-After' => 60]);

sub maintenance ($app) {
    return $app unless $ENV{MAINTENANCE};
    return async sub ($scope, $receive, $send) {
        return await $app->($scope, $receive, $send)
            if $scope->{type} ne 'http' || $scope->{path} eq '/health';
        return await $back_soon->to_app->($scope, $receive, $send);
    };
}

compose(
    routes => [
        route('/' => async sub ($request) { response('Text', 'hello') }),
        route('/health' => async sub ($request) { response('Text', 'ok') }),
    ],
    middleware => [middleware(\&timing), middleware(\&maintenance)],
);
