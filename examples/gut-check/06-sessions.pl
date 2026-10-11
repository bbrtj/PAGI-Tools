#!/usr/bin/env perl
#
# Sessions: a visit counter and a per-visitor name.
#
# Starlette:
#
#     async def visits(request):
#         request.session["visits"] = request.session.get("visits", 0) + 1
#         return JSONResponse({"visits": request.session["visits"],
#                              "name": request.session.get("name")})
#
#     app = Starlette(routes=[...], middleware=[Middleware(SessionMiddleware, secret_key="...")])
#
# Two differences show up at once:
# - Starlette's default session lives in a signed cookie (works across
#   workers); PAGI's default lives in this process's memory, says so in a
#   warning at startup, and the cookie store is a separate distribution
#   (PAGI-Middleware-Session-Store-Cookie).
# - PAGI's get is strict, like State and Stash: $session->get('name') dies
#   when 'name' was never set, to catch typos. Pass a default for optional
#   keys.
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
