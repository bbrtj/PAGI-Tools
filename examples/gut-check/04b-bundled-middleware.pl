#!/usr/bin/env perl
#
# The same two jobs as 04-everyday-middleware.pl, using middleware that ships
# with PAGI-Tools (Runtime and Maintenance). Their documentation only shows
# the PAGI::Middleware::Builder DSL; they work the same way in Compose.
#
# Run:  MAINTENANCE=1 pagi-server --app examples/gut-check/04b-bundled-middleware.pl --port 5000

use v5.40;
use Future::AsyncAwait;

use PAGI::Compose qw(compose);
use PAGI::Response qw(response);
use PAGI::Routing qw(route middleware);

compose(
    routes => [
        route('/' => async sub ($request) { response('Text', 'hello') }),
        route('/health' => async sub ($request) { response('Text', 'ok') }),
    ],
    middleware => [
        middleware('Runtime'),
        middleware('Maintenance',
            enabled      => !!$ENV{MAINTENANCE},
            bypass_paths => ['/health'],
            retry_after  => 60,
        ),
    ],
);
