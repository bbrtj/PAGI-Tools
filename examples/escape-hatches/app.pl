#!/usr/bin/env perl
#
# Escape hatches: the easy way first, then each step down to raw PAGI, all in
# one application. PAGI-Tools is a thin layer over the protocol, so dropping
# down is never a rewrite: a handler can reach the scope and the connection,
# hand back a raw application partway through a request, a route can mount
# one, and a middleware can edit the protocol events itself.
#
#   1. /easy     - a handler returns a response value
#   2. /under    - the same kind of handler reads the raw scope and connection
#   3. /raw      - a handler reads the request the easy way, then answers with
#                  a hand-written application, event by event
#   4. /legacy/* - a raw ($scope, $receive, $send) application at a route
#   5. /stamped  - an app-in, app-out middleware that edits events itself
#
# Run:  pagi-server --app examples/escape-hatches/app.pl --port 5000
# Try:  curl -i 'localhost:5000/easy?who=ada'
#       curl -i localhost:5000/under
#       curl -i 'localhost:5000/raw?who=ada'
#       curl -i localhost:5000/legacy/anything
#       curl -i localhost:5000/stamped

use v5.40;
use Future::AsyncAwait;
use PAGI::Tools qw(compose middleware mount response route);

# 1. The easy way: one Request in, one response value out.
async sub easy ($request) {
    my $who = $request->query_param('who') // 'world';
    return response('Text', "hello, $who");
}

# 2. Reaching under, still the easy way: the raw scope and the server's
#    connection object are one call away.
async sub under ($request) {
    my $scope = $request->scope;
    return response('JSON', {
        scope_type => $scope->{type},
        http       => $scope->{http_version},
        connected  => $request->connection->is_connected ? 1 : 0,
    });
}

# 3. Raw partway through: read the request with the helpers, then answer with
#    a native application. A handler may return one, as well as a response.
async sub raw ($request) {
    my $who = $request->query_param('who') // 'world';
    return async sub ($scope, $receive, $send) {
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({ type => 'http.response.body', body => "raw, $who\n", more => 1 });
        await $send->({ type => 'http.response.body', body => "sent in two events\n" });
    };
}

# 4. A raw application at a route: anything that speaks PAGI mounts as-is
#    (a legacy app, another framework, a hand-tuned endpoint). To give one to
#    route() instead, wrap it in as_app_object (PAGI::Utils): a plain sub
#    there is a handler taking one Request.
my $legacy = async sub ($scope, $receive, $send) {
    my $body = "a raw app at $scope->{root_path}, asked for $scope->{path}";
    await $send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [['content-type', 'text/plain']],
    });
    await $send->({ type => 'http.response.body', body => $body });
};

# 5. Raw middleware: an application in, an application out, editing the
#    response-start event on its way to the server. (wrap_response_headers
#    does this for you; here it is by hand.)
sub stamp ($app) {
    return async sub ($scope, $receive, $send) {
        await $app->($scope, $receive, async sub ($event) {
            if ($event->{type} eq 'http.response.start') {
                $event = { %$event, headers => [@{ $event->{headers} }, ['x-stamped', 'by raw middleware']] };
            }
            await $send->($event);
        });
    };
}

compose(routes => [
    route('/easy'  => \&easy),
    route('/under' => \&under),
    route('/raw'   => \&raw),
    mount('/legacy', app => $legacy),
    route('/stamped' => sub ($request) { response('Text', 'stamped') }, middleware => [middleware(\&stamp)]),
]);
