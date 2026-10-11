#!/usr/bin/env perl
#
# Sessions: a visit counter and a per-visitor name.
#
# - The default session store lives in this process's memory, and says so in
#   a warning at startup; a signed-cookie store is a separate distribution
#   (PAGI-Middleware-Session-Store-Cookie).
# - get is strict, like State and Stash: $session->get('name') dies when
#   'name' was never set, to catch typos. Pass a default for optional keys.
#
# The Starlette version is in README.md.
#
# Run:  pagi-server --app examples/gut-check/06-sessions.pl --port 5000
# Try:  curl -c jar -b jar localhost:5000/visits   (repeat)
#       curl -c jar -b jar -X POST localhost:5000/name -d 'Ada'

use v5.40;
use Future::AsyncAwait;
use PAGI::Tools qw(compose middleware response route session);

async sub visits ($request) {
    my $session = session($request);
    $session->set(visits => $session->get('visits', 0) + 1);
    return response('JSON', {
        visits => $session->get('visits'),
        name => $session->get('name', undef),
    });
}

async sub name ($request) {
    session($request)->set(name => await $request->text);
    return response('Empty');
}

async sub strict ($request) {
    return response('Text', session($request)->get('nmae'));    # a typo
}

compose(
    routes => [
        route('/visits' => \&visits),
        route('/name' => \&name, methods => ['POST']),
        route('/strict' => \&strict),
    ],
    middleware => [middleware('Session')],
);
