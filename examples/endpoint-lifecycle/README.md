# Endpoint lifecycles

One spelling at every route, `endpoint('Class', %args)`, and three ways an
endpoint class can be built. The caller never knows which; the class's
author decides.

| Class | How it is built | It answers |
| --- | --- | --- |
| `NotesApp::Health` | no `BUILD_APP`: `->new(version => '1.0')`, once, when app.pl loads | every request (its hit counter is shared, per worker) |
| `NotesApp::Notes`, `NotesApp::Note` | `BUILD_APP` returns a builder; the builder runs per request | one request |
| `NotesApp::Watch` | the same, per WebSocket connection | one connection |

## The contract

`endpoint('Class', %args)` loads `Class` (a class defined in app.pl itself
needs no file) and then:

- calls `Class->BUILD_APP(%args)` if the class has one, otherwise
  `Class->new(%args)`;
- an object with `to_app` (an endpoint, a Response, any app object) is put at
  the route as it is, and answers every request;
- a coderef is a builder: it is called with a `PAGI::Request` for each request
  (each connection, for WebSocket and SSE) and returns the app object that
  answers it. It may return any app object, a refusal included:

```perl
sub BUILD_APP ($class, %args) {
    return sub ($request) {
        return response('Text', 'no token', status => 403)
            unless $request->header('X-Token');
        return $class->new(%args);
    };
}
```

The builder reads only what the request already carries (headers, cookies,
query and path parameters, state). The WebSocket builder gets a Request too,
not the WebSocket: the object it builds accepts, sends and closes.

`endpoint()` runs when app.pl loads, before lifespan startup, so the store
built at startup is reached at request time through `$request->state` and
`$websocket->state`.

## Moo and Moose

The framework calls only your `new` or `BUILD_APP`, so Moo's `required` and
`default` work: `NotesApp::Notes` requires `current_user`, and a builder
that forgot it fails on that request. A Moose class extending an Endpoint
base needs `use MooseX::NonMoose` after `use Moose`; `endpoint()` refuses one
without it.

## Methods

`PUT /notes` is a 405 with `Allow: GET, HEAD, OPTIONS, POST`. The Router
answers it from `NotesApp::Notes->allowed_methods`, asked of the class, so no
object is built for a method the class does not have. `OPTIONS` reaches the
endpoint, which answers 204 with `Allow`; `HEAD` is answered by `get`.

## Run

```bash
pagi-server --app examples/endpoint-lifecycle/app.pl --port 5000
```

The curl lines are in app.pl's header. `t/example-endpoint-lifecycle.t`
proves the three lifecycles, including two overlapping POSTs that each answer
with their own user.
