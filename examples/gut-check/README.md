# Gut check: PAGI-Tools next to Starlette

Everyday Starlette-shaped applications built with PAGI-Tools, each paired with
a real Starlette version (`starlette/`), to check whether the API is on the
right track. This is a record of how the shapes compare; it is not a bug hunt.

The first pass (2026-10-09) found the rough edges listed under "What the gut
check found". PAGI-Tools 0.003000 smooths them, and the applications here are
written against it; the Starlette versions are unchanged.

## How this was checked

- **Starlette:** 1.7.0 (with httpx 0.28.1 and itsdangerous) in a scratch
  virtualenv.
- **Same requests, both sides:** every pair was driven with the same request
  sequence through each framework's own in-process test client:
  - `PAGI::Test::Client`, kept as `t/example-gut-check.t` in the PAGI-Tools
    test suite;
  - `starlette.testclient.TestClient`.
- **Real servers too:** every PAGI example was also run under `pagi-server`
  and exercised with `curl` (and `websocat` for 03's WebSocket). 07's
  Starlette version was also run under uvicorn.
- **Line counts** below are code lines (not blank, not a comment, not a lone
  `{`, `}` or `};`), with the import lines (Perl's `use` and `package`,
  Python's `import` and `from`) counted separately. From this directory:

  ```
  perl -nE 'if ($ARGV ne $f) { printf "%-32s %d (%d)\n", $f, $c, $i if $f; ($f, $c, $i) = ($ARGV, 0, 0) } next if /^\s*(?:#|$)/ || /^\s*[{}];?\s*$/; $c++; $i++ if /^\s*(?:use|package|import|from)\s/; END { printf "%-32s %d (%d)\n", $f, $c, $i }' *.pl starlette/*.py
  ```

| Pair | What it does | Behaviour | PAGI lines (imports) | Starlette lines (imports) |
|---|---|---|---|---|
| `01-errors-as-responses` | throw a 404 from the model, real bugs get a 500 | identical | 22 (4) | 19 (4) |
| `02-notes-resource` | CRUD resource: class endpoints, lifespan store, named links, typed `{id}` | identical, incl. 204 and the typed-path 404 | 48 (17) | 44 (5) |
| `03-broadcast-hub` | WebSocket chat + SSE watcher + HTTP announce on one fan-out | identical where Starlette can be tested (see below) | 33 (4) | 46 (5) |
| `04-everyday-middleware` | `Server-Timing` and maintenance mode, hand-written | identical | 25 (4) | 26 (7) |
| `04b-bundled-middleware` | the same jobs with Tools' own `Runtime` and `Maintenance` | same statuses and `Retry-After`; the timing header is `X-Runtime`, and the 503 body is the stock "Service Unavailable" | 17 (3) | (none shipped) |
| `05-streaming` | slow NDJSON feed and a custom tab-separated format | identical | 32 (10) | 23 (5) |
| `06-sessions` | visit counter, a name, and a typo'd key | identical | 23 (3) | 17 (5) |
| `07-upload-relay` | relay an upload back, transform it chunk by chunk, checksum it | checksum identical; Starlette's relay and transform fail (see below) | 25 (4) | 22 (4) |
| `08-negotiation` | one URL, HTML or JSON by `Accept` (q-values), else 406 | same for plain `Accept`s; with `text/html;q=0.9, application/json;q=0.5` PAGI serves HTML, the usual hand-written Starlette check serves JSON | 11 (3) | 12 (3) |

The first pass measured the PAGI side at 28, 50, 35, 28, 19, 34, 26, 27 and 13
lines (6, 19, 6, 7, 5, 12, 6, 6 and 5 of them imports).

Run any PAGI one with `pagi-server --app examples/gut-check/<file> --port 5000`.
Run a Starlette one with `pip install starlette uvicorn itsdangerous`, then
`cd examples/gut-check/starlette && uvicorn s01_errors:app --port 8000`.

## Verdict

**On the right track.**
- **Behaviour:** every pair behaves the same as its Starlette twin, status
  codes and headers included, except where the table says otherwise: 07's
  relay and transform, which Starlette cannot do, and 08's q-value case. 04b
  has no twin, and its timing header has another name.
- **Where PAGI did better, measured:**
  - **Testing realtime code.** `PAGI::Test::Client` drives a WebSocket, an
    open SSE stream and an HTTP request together in one test (03). Starlette's
    `TestClient` buffers a response until it ends, so a request to an endless
    SSE stream never returns, and the SSE half of 03 cannot be tested in
    Starlette.
  - **Streaming an upload straight back out (07).** PAGI relays a 4,000,001-byte
    upload byte for byte (`pipe_from`) and transforms it chunk by chunk, under
    `pagi-server` and in its test client. Starlette 1.7 can't: a
    `StreamingResponse` that reads `request.stream()` returns 0 bytes (relay) or
    hangs (transform), under uvicorn and in its TestClient. Its own disconnect
    watcher reads `receive()` and takes the body (`starlette/responses.py`). The
    checksum route, which reads the body before responding, matches on both
    sides.
  - **Content negotiation built in (08).** `$request->preferred_type('html',
    'json')` honours quality values and returns the name you asked for.
    Starlette ships no helper, and the usual hand-written header check picks
    JSON for `text/html;q=0.9, application/json;q=0.5`.
  - **Negotiated error pages, one line away.** Compose's default 404 is plain
    text, exactly like Starlette's (checked with HTML, JSON and problem+json
    `Accept`s). `http_default => not_found()` from `PAGI::Pages` serves an HTML
    page to browsers and RFC 9457 `application/problem+json` to API clients.
    Starlette has nothing comparable built in.
  - **Throwing (01).** `PAGI::Exception::HTTP->throw(404, ...)` from deep in
    the model answers 404 with no configuration, as Starlette's `HTTPException`
    does; 01's one small handler only renders the errors it expects as JSON. A
    thrown response answers itself too: `die response('Redirect', '/login')`
    redirects. Starlette can raise only `HTTPException`; raising a response
    object gives a 500 there (checked).
  - **Fan-out without extra machinery (03).** PAGI's best-effort sends let one
    hub serve three protocols in 33 lines. The Starlette version needs a queue
    and a sender task per WebSocket (46 lines), or the separate `broadcaster`
    package.
  - **Batteries (04b).** Tools bundles 29 middlewares, including
    `Maintenance`, `Runtime`, `RateLimit`, `ETag` and `SecurityHeaders`.
    Starlette 1.7 ships 9 user-facing ones (authentication, body limit, CORS,
    GZip, HTTPS redirect, OpenTelemetry, sessions, trusted hosts, WSGI), and
    its sessions need the extra `itsdangerous` package.
  - **Responses are values.** A 503 page built once serves every request (04),
    and a ten-line Stream subclass is a new streaming format (05).
  - **Strict session keys (06).** `get('nmae')` dies with "Available keys:
    name, visits"; Starlette's `session["nmae"]` is a bare `KeyError`. It's the
    same contract with a better message.
- **Length:** PAGI is now shorter in three of the eight pairs with a Starlette
  version (03, 04 and 08) and longer in five (01, 02, 05, 06 and 07), by 3 to 9
  lines. One `use PAGI::Tools qw(...)` line replaced the per-module imports;
  02's 17 import lines are mostly the `package` and `use` lines each of its
  four packages repeats (Python's file has 5). Without imports, PAGI's logic is
  shorter for 02 (31 against 39 lines), 03 (29 against 41) and 08 (8 against
  9), and 2 to 8 lines longer for the rest.

None of the rough edges below was architectural.

## What the gut check found, and what changed

Most important first, as found; each now says what PAGI-Tools 0.003000 does.

1. **There was no single import for an application.** Changed:
   `use PAGI::Tools qw(compose response route ...)` imports any of 20 toolkit
   functions by name, in one line, with the tags `:routes`, `:urls` and `:all`.
   It turns nothing on implicitly: `use Future::AsyncAwait;` stays the
   application's own line. The per-module imports still work.

2. **A thrown response was a 500 by default.** Changed: ErrorHandler reads one
   small protocol from what is thrown. An object with `status_code` is an HTTP
   error (`PAGI::Exception::HTTP` is the one Tools ships); a response, or
   anything else with `to_app`, answers itself unless a handler renders it: a
   page below 400, such as a redirect, always answers itself. 01 now
   throws `PAGI::Exception::HTTP` and keeps its handler only for the JSON house
   style.

3. **The query accessors disagreed across Request, WebSocket and SSE.**
   Changed: all three have exactly `query_param`, `query_params`,
   `raw_query_param` and `raw_query_params`. WebSocket's `query` and
   `raw_query`, and Request's deprecated `query`, `raw_query`, `form` and
   `raw_form`, are gone.

4. **The best-effort send families overlapped.** Changed:
   `send_*_if_connected` is gone. `try_send_*` sends only while connected (it
   returns false before `accept` too) and is the one best-effort family.

5. **Middleware: the docs used the other composition style.** Changed: every
   bundled middleware's SYNOPSIS opens with
   `compose(... middleware => [middleware('Name', ...)])`, then shows
   `PAGI::Middleware::Name->new(...)->wrap($app)`; Builder is for applications
   that do not use Compose. There is still no request-level `call_next`; the
   `app -> app` function form (04) is the mechanism.

6. **Lifespan state is written as a hash and read as an object.** Kept, and
   explained in `PAGI::State`: each request gets a shallow copy of the state, so
   a top-level write in a request would silently desync from every other one;
   startup writes the hash once, and requests read a read-only view.
   `$request->state` is now always an object, and on a request with no state
   (a `PAGI::Test::Client` without `lifespan => 1`) `get` says so instead of
   "Can't call method".

7. **Links: names inside mounts use a slash.** Kept, and a correction:
   `PAGI::Routing` documented the scheme fully (its "REVERSE ROUTING AND
   INSPECTION" section); only `PAGI::Routing::URL`'s `path_for` lacked a mount
   example, which it now has, with the Cookbook recipe "Linking inside a
   mounted app". Names are logical addresses, not URL paths: `api/note` is the
   route `note` in the mount `api`, and a handler inside that mount reaches a
   sibling as plain `note`, wherever the mount is placed, which Starlette's
   `api:note` cannot do.

8. **Route constraints name a Perl function inside a string.** Kept:
   `{id:&Int}` is the compact form, and the docs now lead with the explicit
   one, `constraints => { id => Int }`, which 02 uses.

9. **The test client didn't drive off-loop I/O during a request.** A
   correction and a fix: plain handlers awaiting `Future::IO` always worked;
   only a streamed response whose producer awaited real I/O failed (a 500), and
   WebSocket and SSE receive timeouts were not honoured. `PAGI::Test::Client`
   now drives the event loop in all of them, so 05 is tested in-process like the
   others.

10. **SSE handler ceremony.** Real SSE handlers checked `return if
    $sse->is_closed;` after nearly every `await` during setup. Changed, in
    the docs and examples: `start` and `keepalive` were already safe once the
    client has gone, and a setup step that may find it gone uses the
    best-effort send, `return unless await $sse->try_send_event(...)`. Strict
    sends stay for messages that must arrive, and stay loud.
    `examples/sse-dashboard` now reads that way (see "HANDLERS AND
    DISCONNECTS" in `PAGI::SSE`). 03 keeps one `is_closed` check: it is not a
    send guard, but keeps a watcher that already left from being registered.

11. **There was no "after the response" task.** A correction: the connection's
    `on_complete` already runs work once the response has been delivered, in
    the same place as Starlette's `BackgroundTask` (measured order: handler
    returned, task ran, client got the response). Nothing showed it; the
    Cookbook now has "Work After the Response", and `examples/background-tasks`
    shows it next to work started at once, without IO::Async.

12. **Small things:**
    - an optional session key needs an explicit default (`get('name', undef)`):
      kept, the same idiom as State and Stash, and now shown in
      `PAGI::Session`'s `get`;
    - `PAGI::Endpoint::HTTP`'s SYNOPSIS now uses `response('JSON', ...)`;
    - the test client's "exception after response completed" warning for an
      answered 500 is what a server logs; `PAGI::Test::Client` shows how a test
      captures and asserts it, and since finding 2 only real 5xx errors raise
      it;
    - **App files compile in different packages in tests and under the
      server.** `pagi-server` loads an app file with `do` from inside
      `PAGI::Server::Runner`, so the file's top-level subs land in that package;
      in a test, or a plain `do` from `main`, they land in `main`. Still open,
      in PAGI-Server: it will load each app file in a sandbox package of its
      own, as Plack does. Until then, call your own subs unqualified.

Checked and fine as it is:
- **`query_params` returns a multi-value object** that JSON can't encode.
  Starlette's `JSONResponse(request.query_params)` is also a 500 (checked), so
  this is parity.
- **WebSocket `accept` against SSE `start`,** which follows the protocols.
- **Strict handler returns,** where returning a hashref is an error.
- **Malformed JSON over a WebSocket.** `each_json` now closes with 1007
  (invalid payload data) and ends the loop; an `on_invalid_json` option, or a
  `handle_invalid_json` method in a subclass, replaces that. Starlette's
  `receive_json` raises `JSONDecodeError` out of the handler.
- **Running a legacy app beside new routes** is parity: Tools has
  `PAGI::App::WrapPSGI` (see `examples/psgi-bridge`), and Starlette 1.7 still
  ships `WSGIMiddleware`.

## Time spent

Measured from git and file timestamps, not estimated:
- **Start:** the branch was created at 20:24:59 (2026-10-09, -0500), and the
  first probe script was written at 20:25:53.
- **First pass:** committed at 20:33:13. It was a single sketch, without
  Starlette run and with some comparisons from memory.
- **Checked pass:** at 21:10:49, after Starlette 1.7 was installed, every pair
  was run on both sides and those comparisons were replaced with
  measurements.
- **More areas:** upload relay, negotiation, mount names, error pages and
  WebSocket JSON were explored and committed after that.
- **Real-server pass:** every example was run under `pagi-server` with
  `curl`/`websocat`, finishing at 21:25:22, an hour after the branch was
  created.
