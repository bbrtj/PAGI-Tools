# Gut check: PAGI-Tools next to Starlette

An hour spent building everyday Starlette-shaped things with PAGI-Tools, to
check whether the API is on the right track. Each example opens with the
Starlette code it is compared against. This is a record of how the shapes
feel; it is not a bug hunt.

| Example | What it does | Starlette counterpart |
|---|---|---|
| `01-errors-as-responses.pl` | A handler throws the response itself; one ErrorHandler handler answers with it | `HTTPException` + `exception_handlers` |
| `02-notes-resource.pl` | A CRUD resource: class-based endpoints, a store built at startup, links from route names, typed path parameters | `HTTPEndpoint`, `lifespan`, `url_for`, `{id:int}` |
| `03-broadcast-hub.pl` | WebSocket chat, an SSE watcher and an HTTP announce endpoint sharing one fan-out | the separate `broadcaster` package |
| `04-everyday-middleware.pl` | `Server-Timing` and a maintenance-mode short circuit | `BaseHTTPMiddleware.dispatch(request, call_next)` |
| `05-streaming.pl` | A slow NDJSON feed and a custom tab-separated format | `StreamingResponse(async_generator)` |

Run any of them with `pagi-server --app examples/gut-check/<file> --port 5000`.

How they were checked:
- 01-04 through `PAGI::Test::Client`, including WebSocket and SSE clients for
  03;
- 05 under `pagi-server` with `curl` (see "In-process testing" below).

## Verdict

**On the right track.** The response-value model held up everywhere I pushed
on it, and several things are shorter or cleaner than in Starlette:
- **Responses are values.** A 503 page is built once and reused by every
  request (04), a handler can throw a response (01), and middleware can
  short-circuit by answering with a value (04).
- **One fan-out across three protocols** in about 40 lines of plain Perl, with
  disconnect cleanup, and all of it testable in-process (03).
- **A new streaming format is about 10 lines:** a Stream subclass with
  `format_item` (05).
- **Sensible defaults:**
  - plain `sub` handlers work, as well as `async sub`;
  - a bad JSON body is a 400 without any code;
  - a typed path parameter that doesn't match is a 404 (02).
- **Streaming producers see disconnects** and get a backpressure point at
  every write (05).

The rough edges are naming and consistency, plus two missing conveniences.
None of them is architectural.

## Shapes that felt ugly or inconsistent

Most important first.

1. **A thrown response is a 500, not an answer.** `die response('JSON', ...,
   status => 404)` gives "Internal Server Error". The value model makes the
   Starlette `HTTPException` pattern almost free, but you have to add it
   yourself (six lines, 01). The Thunderhorse values port does it by default.
   A default (or a one-word option) in Compose's ErrorHandler would let
   applications drop the repeated "return a 404 JSON" blocks that
   `starlette-apples` is full of.

2. **The query accessors disagree across Request, WebSocket and SSE.**

   | | single value | all values |
   |---|---|---|
   | `PAGI::Request` | `query_param` (`query` is deprecated, and warns) | `query_params` |
   | `PAGI::WebSocket` | `query` only (no `query_param`) | `query_params` |
   | `PAGI::SSE` | `query_param` | `query_params` |

   The same idea has three spellings, and the one Request deprecates is the
   only one WebSocket has.

3. **The best-effort send families overlap.** WebSocket has both
   `try_send_text`/`_bytes`/`_json` (never throws, returns a boolean) and
   `send_text_if_connected`/... (a silent no-op when closed). SSE has the
   `try_send*` family only. Two near-identical families on one class, with
   only one of them on its sibling, is a lot to choose between.

4. **Lifespan state is written as a hash and read as an object.** Startup does
   `$state->{notes} = ...`; handlers do `$request->state->get('notes')`, and
   `$request->state` can be undef, which is why `starlette-apples` has
   `or die '... requires Compose lifespan state'`. One shape would be easier
   to remember (Starlette: `app.state.notes` on both sides).

5. **Two ways to compose middleware, and two ways to write it.**
   - Compose takes `middleware => [middleware(...)]`;
     `PAGI::Middleware::Builder` has its own `builder { enable ... }` DSL
     (shown in PAGI::Middleware's SYNOPSIS).
   - Middleware is written either as a function (`app -> app`) or as a class
     with `wrap`/`modify_scope`.
   - There's no request-level helper, so everyday request-level checks mean
     writing raw scope/send code (04). A `call_next`-style sugar might pay for
     itself; the function form is fine underneath it.

6. **Links are functions, not request methods.** It's
   `path_for($request, 'note', {id => 1})` from `PAGI::Routing::URL`, where
   Starlette has `request.url_for('note', id=1)`. It's a small thing, but it is
   an extra import in every file that builds links.

7. **Route type constraints name a Perl function inside a string.**
   `'/notes/{id:&Int}'` works only because `use Types::Standard qw(Int)` put
   `Int` in the caller's package. It's powerful, but it couples a string to an
   import invisibly; a reader can't tell where `&Int` comes from.

8. **The SSE handler ceremony.** Real SSE handlers repeat
   `return if $sse->is_closed;` after almost every `await` (see
   `examples/sse-dashboard`). Starlette-style generators simply stop when the
   client leaves. `run`/`each` cover the steady state, but the setup phase is
   noisy.

9. **There's no "after the response" task.** Starlette's `BackgroundTask` runs
   once the response is sent. Here, work is started before returning and handed
   to `PAGI::FutureOwner`, so it races the response instead of following it.
   Also, `examples/background-tasks` uses `IO::Async::Function`, which cuts
   against the "Future::IO only" rule for application code.

10. **The documentation's house style drifts.** `PAGI::Endpoint::HTTP`'s
    SYNOPSIS builds responses with `PAGI::Response::JSON->new(...)` and
    `PAGI::Response::Empty->new(...)`; everything else uses `response('JSON',
    ...)`.

11. **In-process testing gaps.**
    - **Timers:** the test client couldn't run 05's timer-based stream
      (`Future::IO->sleep`): the request came back 500. It worked under
      `pagi-server`. Starlette's `TestClient` runs `asyncio.sleep` without fuss.
      If it is just a missing setup step, it should be in the test client's
      docs.
    - **Noise:** an error that was handled and answered with a 500 still makes
      the test client warn "exception after response completed", so tests that
      exercise error pages are noisy by default.

12. **`query_params` is a `Hash::MultiValue`**, so
    `response('JSON', { all => $request->query_params })` fails to encode. This
    is consistent with Starlette's `MultiDict`, so it's minor, but an obvious
    `->as_hashref` mention in the Request docs would save a lookup.

Also noticed, and fine as it is: WebSocket `accept` versus SSE `start`, which
follows the protocols; and strict handler returns (returning a hashref is an
error), which is the right call for a toolkit. Frameworks add the DWIM.
