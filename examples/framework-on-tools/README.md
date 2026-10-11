# A Framework on PAGI-Tools

`lib/Tiny.pm` is a small opinionated web framework built on PAGI-Tools, the
shape a Sinatra, Flask or FastAPI user expects, and `app.pl` is a notes
service written against it. It exists to answer one question of the
whipupitude gap analysis: when someone builds a framework on Tools, which
seams do they stand on, and what does each cost? Each piece of Tiny is
marked with the seam it uses.

## Run

```bash
pagi-server --app examples/framework-on-tools/app.pl --port 5000
```

## What the application looks like

```perl
use Tiny;

service notes => sub ($state) { { next => 1, by_id => {} } };
plugin 'Timing', name => 'notes';

around async sub ($req, $next) {
    my $sent = await $next->();
    $sent->headers->set('X-Powered-By', 'Tiny on PAGI-Tools');
    return $sent;
};

on_error 'Note::NotFound' => sub ($req, $exc) {
    return response('JSON', { error => 'no such note', id => $exc->id }, status => 404);
};

get '/notes' => name => 'notes', desc => 'List the notes', sub ($req) {
    my $notes = $req->svc('notes')->{by_id};
    return [ map { $notes->{$_} } sort { $a <=> $b } keys %$notes ];
};

get '/notes/{id}' => constraints => { id => Int }, sub ($req) {
    return find_note($req, $req->param('id'));
};

raw '/raw' => async sub ($scope, $receive, $send) { ... };

get '/openapi.json' => openapi(title => 'Tiny notes');

tiny;
```

## The seams, and what each cost

| Tiny feature | Built on | Cost |
|---|---|---|
| verbs with one-Request handlers | `route($path => $endpoint, methods => [...])` | none; two routes on one path merge their `Allow` |
| the framework's own Request (`param`, `svc`) | `PAGI::Request` subclass, handed to handlers by `request_response(..., request_factory => ...)` | one indirection: a bare coderef at a Route always gets a plain `PAGI::Request`, so every handler is wrapped |
| plain-value returns (hashref is JSON, string is HTML) | the same wrapper, `response('JSON'...)`/`response('HTML'...)` | 5 lines |
| `before` hooks | the same wrapper | 4 lines |
| `around` with Starlette's `call_next` | a native middleware wrapping `$send`: `$next` starts the inner app and resolves on `http.response.start`; the start event is held until the hook returns | 38 lines of raw-protocol code, the only such code in Tiny, and the delicate part: replacing the response has to fail the held send to unwind the handler |
| services built at startup | Compose `lifespan => { startup }`, read with `$request->state` | none |
| typed path parameters | `constraints => { id => Int }`, or the compact `{id:&Int}` | `route()` looks a compact provider up in its caller, which is Tiny, so Tiny passes `declaration_package` (the application's package). The app keeps the explicit form because the OpenAPI document reads `Route->constraints`, which holds only explicit constraints |
| `on_error` class-to-response mapping | one `ErrorHandler` handler reading `error_context($req)->exception` | none; the handler sees a plain `PAGI::Request`, not Tiny's |
| plugins | a package with `register($app)` using the same hooks | none |
| the raw escape hatch | `route($path => as_app_object($code), methods => '*')` | none |
| an OpenAPI document | `Compose->router->routes`, then `Route->path/methods/parameters/constraints/name/desc` and `Mount->app` | none; a `Types::Standard` type names its OpenAPI type through `display_name` |

Order matters and Tools leaves it to the framework: the `around` hooks wrap
the ErrorHandler, as Starlette's user middleware wraps its
ExceptionMiddleware, so a mapped error response passes through them too.
Written the other way round, `/notes/9` lost its `X-Powered-By`.

Tiny is 175 code lines; the plugin 13; the application 47.

## Try

```bash
curl -i localhost:5000/notes
curl -i -X POST localhost:5000/notes -H 'Content-Type: application/json' -d '{"text":"buy milk"}'
curl -i localhost:5000/notes/1
curl -i localhost:5000/notes/9            # 404 from a thrown Note::NotFound
curl -i localhost:5000/notes/x            # 404: the Int constraint does not match
curl -i localhost:5000/admin              # 403 from the before hook
curl -i 'localhost:5000/admin?token=letmein'
curl -i -X PUT localhost:5000/notes/1     # 405, Allow: GET, HEAD, DELETE
curl -i localhost:5000/raw                # the raw application
curl -s localhost:5000/openapi.json | python3 -m json.tool
```

## See also

- `PAGI::Routing`, "CONSTRUCTORS AND CODE POSITION" and "REVERSE ROUTING AND
  INSPECTION"
- `PAGI::Routing::RequestResponse`, the `request_factory` seam
- `PAGI::Middleware::ErrorHandler` and `PAGI::ErrorContext`
- `PAGI::Tools::Cookbook`, "Custom Request Route Helpers"
- `examples/gut-check/04-everyday-middleware.pl`, middleware as plain
  functions without a `call_next`
