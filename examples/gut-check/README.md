# Gut check: PAGI-Tools next to Starlette

Everyday Starlette-shaped applications built with PAGI-Tools, each paired with
a real Starlette version (`starlette/`), to check whether the API is on the
right track. This is a record of how the shapes compare; it is not a bug hunt.

## How this was checked

- **Starlette:** 1.7.0 (with httpx 0.28.1 and itsdangerous) in a scratch
  virtualenv.
- **Same requests, both sides:** every pair was driven with the same request
  sequence through each framework's own in-process test client:
  - `PAGI::Test::Client`;
  - `starlette.testclient.TestClient`.
- **The exception:** `05-streaming.pl` could only be checked under
  `pagi-server`, for the reason in finding 9.
- **Real servers too:** every PAGI example was also run under `pagi-server`
  and exercised with `curl` (and `websocat` for 03's WebSocket). 07's
  Starlette version was also run under uvicorn.
- **Line counts** below are code lines (no blanks, comments or lone braces),
  with the import/package lines counted separately.

| Pair | What it does | Behaviour | PAGI lines (imports) | Starlette lines (imports) |
|---|---|---|---|---|
| `01-errors-as-responses` | throw a 404 from the model, real bugs get a 500 | identical | 28 (6) | 19 (4) |
| `02-notes-resource` | CRUD resource: class endpoints, lifespan store, named links, typed `{id}` | identical, incl. 204 and the typed-path 404 | 50 (19) | 44 (5) |
| `03-broadcast-hub` | WebSocket chat + SSE watcher + HTTP announce on one fan-out | identical where Starlette can be tested (see below) | 35 (6) | 46 (5) |
| `04-everyday-middleware` | `Server-Timing` and maintenance mode, hand-written | identical | 28 (7) | 26 (7) |
| `04b-bundled-middleware` | the same jobs with Tools' own `Runtime` and `Maintenance` | same statuses and headers; the 503 body is the stock "Service Unavailable" | 19 (5) | (none shipped) |
| `05-streaming` | slow NDJSON feed and a custom tab-separated format | identical | 34 (12) | 23 (5) |
| `06-sessions` | visit counter, a name, and a typo'd key | identical | 26 (6) | 17 (5) |
| `07-upload-relay` | relay an upload back, transform it chunk by chunk, checksum it | checksum identical; Starlette's relay and transform fail (see below) | 27 (6) | 22 (4) |
| `08-negotiation` | one URL, HTML or JSON by `Accept` (q-values), else 406 | same for plain `Accept`s; with `text/html;q=0.9, application/json;q=0.5` PAGI serves HTML, the usual hand-written Starlette check serves JSON | 13 (5) | 12 (3) |

Run any PAGI one with `pagi-server --app examples/gut-check/<file> --port 5000`.
Run a Starlette one with `pip install starlette uvicorn itsdangerous`, then
`cd examples/gut-check/starlette && uvicorn s01_errors:app --port 8000`.

## Verdict

**On the right track.**
- **Behaviour:** every pair behaves the same as its Starlette twin, status
  codes and headers included.
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
  - **Throwing the response itself (01).** With one small handler, a thrown
    `response('JSON', ...)` answers the request. Starlette can raise only
    `HTTPException`; raising a response object gives a 500 there (checked).
  - **Fan-out without extra machinery (03).** PAGI's best-effort sends let one
    hub serve three protocols in 35 lines. The Starlette version needs a queue
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
- **Where PAGI is longer:** seven of the eight pairs with a Starlette version
  (only 03 is shorter; 08 is 13 lines against 12), and it's mostly imports. Each Perl package block repeats its `use` lines (19 in 02
  against Python's 5). Without imports, PAGI's logic is shorter for 02 (31
  against 39 lines) and 03 (29 against 41), and 2 to 8 lines longer for the
  rest. See finding 1.

None of the rough edges below is architectural.

## Shapes that felt ugly or inconsistent

Most important first.

1. **There is no single import for an application.** Every handler package
   repeats `use Future::AsyncAwait; use PAGI::Response qw(response);
   use PAGI::Routing qw(...); ...`, which is most of the size gap in the table.
   A bundle (say `use PAGI::Tools ':app'`, enabling async/await and exporting
   `response`, `route`, `compose`, `middleware`, `session`), as
   Mojolicious::Lite and Dancer2 offer, would make PAGI the shorter side in
   most pairs.

2. **A thrown response is a 500 by default.** Starlette answers
   `raise HTTPException(404)` with a 404 out of the box (checked). In PAGI,
   `die response('JSON', ..., status => 404)` is a 500 until you add the six-line
   ErrorHandler handler in 01. The Thunderhorse values port does this by
   default. Compose's ErrorHandler could too, which would remove the repeated
   "return a 404 JSON" blocks `starlette-apples` is full of.

3. **The query accessors disagree across Request, WebSocket and SSE.**

   | | single value | all values |
   |---|---|---|
   | `PAGI::Request` | `query_param` (`query` is deprecated, and warns) | `query_params` |
   | `PAGI::WebSocket` | `query` only (no `query_param`) | `query_params` |
   | `PAGI::SSE` | `query_param` | `query_params` |

   The deprecated short names on Request don't even map to the same shape:
   `query()` becomes the single-value `query_param()`, `form()` becomes the
   all-values `form_params()`, and `raw_query()`/`raw_form()` follow the same
   split. WebSocket keeps `query` and `raw_query` as live methods.

4. **The best-effort send families overlap.** WebSocket has `try_send_text`/
   `_bytes`/`_json` (never throws, returns a boolean) and
   `send_text_if_connected`/... (a silent no-op when closed). SSE has only the
   `try_send*` family.

5. **Middleware: two composition styles, and the docs use the other one.**
   Compose takes `middleware => [middleware('Runtime')]`, but the bundled
   middlewares' docs (`Maintenance`, `Runtime` and others) show only
   `PAGI::Middleware::Builder`'s `builder { enable ... }`. I hand-wrote 04
   before finding that 04b already existed. There's also no request-level
   `call_next` convenience; the `app -> app` function form is fine underneath
   one.

6. **Lifespan state is written as a hash and read as an object.** Startup does
   `$state->{notes} = ...`; handlers do `$request->state->get('notes')`, and
   `$request->state` can be undef (hence `starlette-apples`' `or die`).
   Starlette uses `app.state.notes` on both sides.

7. **Links: a function or a facade, never a request method, and names inside
   mounts use a slash.**
   - **The calls:** it's `path_for($request, 'note', {id => 1})`, or
     `url($request)->path_for(...)`, against Starlette's
     `request.url_for('note', id=1)`. `url_for` takes a params hashref in one
     call form and named `query =>`/`fragment =>` options in the other.
   - **Names inside a mount:** a route named `note` inside a mount named `api`
     is `api/note` (checked: `note`, `api.note` and `api:note` are "unknown
     route name"). Starlette spells it `api:note` (checked). The slash reads
     like a path, and `PAGI::Routing::URL`'s docs never show it; I found it by
     trying spellings.

8. **Route constraints name a Perl function inside a string.**
   `'/notes/{id:&Int}'` works because `use Types::Standard qw(Int)` put `Int`
   in the caller's package. A reader can't see where `&Int` comes from.

9. **The test client doesn't drive off-loop I/O during a request.**
   - **What happens:** a stream whose producer awaits `Future::IO->sleep` gets
     an immediate 500 ("lost its returning future"), with or without
     `Future::IO::Impl::IOAsync` loaded.
   - **What works:** the same app works under `pagi-server` (five ticks over
     1.1 s), and the client does drive the loop for lifespan startup and
     shutdown.
   - **Starlette:** its TestClient runs the equivalent `asyncio.sleep` stream
     fine (1.0 s).
   - **Docs:** the limit isn't documented.

10. **SSE handler ceremony.** Real SSE handlers check
    `return if $sse->is_closed;` after nearly every `await` during setup (see
    `examples/sse-dashboard`).

11. **There's no "after the response" task.** Starlette's `BackgroundTask` runs
    once the response is produced (its TestClient waits for it: measured order
    "handler returned, task ran, client got 200"). Here, work is started before
    the handler returns and handed to `PAGI::FutureOwner`, so it races the
    response. `examples/background-tasks` also uses `IO::Async::Function`,
    against the "Future::IO only" rule for application code.

12. **Small things:**
    - an optional session key needs an explicit undef default
      (`get('name', undef)`);
    - `PAGI::Endpoint::HTTP`'s SYNOPSIS uses `PAGI::Response::JSON->new` rather
      than the house style, `response('JSON', ...)`;
    - the test client warns "exception after response completed" even for
      errors that were answered with a 500, so tests of error pages are noisy.
    - **App files compile in different packages in tests and under the
      server.** `pagi-server` loads an app file with `do` from inside
      `PAGI::Server::Runner`, so the file's top-level subs land in that package
      (a `do`-loaded file starts in its caller's package; checked). In a test,
      or a plain `do` from `main`, they land in `main`. My first 02 called
      `main::store` and passed every in-process test, then failed with
      "Undefined subroutine" under `pagi-server`. A top-level `sub run` or
      `sub mode` in an app file would also replace Runner's own method of that
      name. Plack loads `.psgi` files into a per-file sandbox package for this
      reason.

Checked and fine as it is:
- **`query_params` returns a multi-value object** that JSON can't encode.
  Starlette's `JSONResponse(request.query_params)` is also a 500 (checked), so
  this is parity.
- **WebSocket `accept` against SSE `start`,** which follows the protocols.
- **Strict handler returns,** where returning a hashref is an error.
- **Malformed JSON over a WebSocket** is parity, with one shared weakness.
  PAGI's `each_json` closes the connection with 1011 (internal error);
  Starlette's `receive_json` raises `JSONDecodeError` out of the handler (both
  checked). RFC 6455's 1007 (invalid payload data) is the precise code for a
  client's bad message, and `each_json` is the natural place to send it.
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
