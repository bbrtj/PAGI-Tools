# Escape Hatches Example

The easy way first, then each step down to raw PAGI, in one small
application. PAGI-Tools is a thin layer over the protocol, so going lower
when you need to is a step, not a rewrite: you keep the helpers for the parts
they fit and drop to events only where you want control.

## Run

```bash
pagi-server --app examples/escape-hatches/app.pl --port 5000
```

## The ladder

1. **`/easy`: the everyday shape.** A handler takes one `PAGI::Request` and
   returns a response value (`response('Text', ...)`).
2. **`/under`: reaching under, still the easy way.** The same kind of
   handler reads the raw scope (`$request->scope`) and the server's
   connection object (`$request->connection`), the spec's own interface for
   disconnects and connection state.
3. **`/raw`: raw partway through a request.** The handler reads the query
   with the helpers, then returns a native `($scope, $receive, $send)`
   application, which sends the response event by event: here, a body in two
   `http.response.body` events. A handler may return a response or an
   application; the router runs either.
4. **`/legacy/*`: a raw application at a route.** Anything that speaks PAGI
   mounts as-is with `mount('/legacy', app => $app)`: a legacy app, another
   framework, a hand-tuned endpoint. It sees `root_path` and the path below
   the mount. To give a native application to `route()` instead, wrap it in
   `as_app_object` (PAGI::Utils), because a plain sub there is a handler
   taking one Request.
5. **`/stamped`: raw middleware.** An application in, an application out,
   editing the `http.response.start` event on its way to the server. It goes
   in a route's `middleware` list with `middleware(\&stamp)`.
   `wrap_response_headers` does the same edit for you; this is it by hand.

## Try

```bash
curl -i 'localhost:5000/easy?who=ada'
curl -i localhost:5000/under
curl -i 'localhost:5000/raw?who=ada'
curl -i localhost:5000/legacy/anything
curl -i localhost:5000/stamped
```

## See also

- `PAGI::Tools`, "HANDLERS AND APPLICATIONS" - what a sub means in each slot
- `PAGI::Spec::Www` - the events the raw rungs send
- `examples/framework-on-tools` - a small framework built on these seams
- `examples/gut-check/04-everyday-middleware.pl` - middleware with
  `wrap_response_headers`
