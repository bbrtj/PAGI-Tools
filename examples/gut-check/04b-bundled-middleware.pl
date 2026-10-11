#!/usr/bin/env perl
#
# The same two jobs as 04-everyday-middleware.pl, using middleware that ships
# with PAGI-Tools (Runtime and Maintenance), named in Compose's middleware
# list exactly as their documentation shows. Two details differ from 04:
# Runtime's header is X-Runtime, in seconds, not Server-Timing, and the
# maintenance page is the stock "Service Unavailable" (Maintenance's response
# option sets your own).
#
# Run:  MAINTENANCE=1 pagi-server --app examples/gut-check/04b-bundled-middleware.pl --port 5000

use v5.40;
use Future::AsyncAwait;
use PAGI::Tools qw(compose middleware response route);

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
