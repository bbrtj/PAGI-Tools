# Content Negotiation Example

One notes resource served to three kinds of client from the same URLs:
browsers get HTML pages, htmx gets HTML fragments, and API clients get JSON.
It shows every part of content negotiation in PAGI-Tools in one small app.

## Run

```bash
pagi-server --app examples/content-negotiation/app.pl --port 5000
```

Visit http://localhost:5000/notes and add a few notes. With JavaScript the
form posts through htmx and the list updates in place; without it, the form
posts and redirects.

## What it shows

- **The middleware decides.** `PAGI::Middleware::ContentNegotiation`,
  declared with `supported_types => ['html', 'json']`, picks the
  representation from `Accept` (quality values included), refuses a request
  neither can satisfy, and sends `Vary: Accept` on every answer: 200s, 201s,
  the 303, the 404s and the refusal. A handler cannot forget it.
- **Handlers say what each representation is.** `respond_to($request,
  html => sub {...}, json => sub {...})` calls only the branch the middleware
  chose. A misspelled branch (`htlm`), a missing one, or a type the
  middleware did not declare dies on the first request, whatever the client
  sent. Where an `if` reads better, `negotiated_type($request)` is the
  choice itself (the 404 in `show`).
- **Input is a separate question.** A POST is read by its `Content-Type`: a
  form or JSON, anything else is a 415. `Accept` then decides the answer: a
  201 with `Location` for an API client, a 303 back to the list for a
  browser, the updated list for htmx.
- **htmx and Vary on another header.** When the request carries
  `HX-Request: true`, the list answers the fragment htmx swaps in instead of
  the whole page, and says `Vary: HX-Request` (the middleware merges
  `Accept` in). htmx's own docs also ask you to turn off
  `htmx.config.historyRestoreAsHxRequest` when a server branches on
  `HX-Request`, so a history restore is not cached as a fragment.
- **Negotiation has a scope.** The middleware sits on the `/notes` mount
  only. `/health` answers plain text to anyone and carries no `Vary`.
  Declared on the whole app, it would refuse a health check that asks for
  `image/png`.
- **The refusal is the app's own.** `refuse` replaces the stock plain-text
  406 with an RFC 9457 problem document (`response('Problem', {...})`).

One boundary to know: a response thrown with `die response('JSON', ...)` is
sent by Compose's error handler, outside the mount's middleware, so it gets
no `Vary`. Return answers that depend on `Accept`; `show` returns its 404
for that reason.

## Try

```bash
curl -i -H 'Accept: application/json' localhost:5000/notes
curl -i -H 'Accept: application/json' -H 'Content-Type: application/json' \
     -d '{"text":"buy milk"}' localhost:5000/notes           # 201, Location
curl -i -d 'text=call mum' localhost:5000/notes               # 303 to /notes/
curl -i -H 'HX-Request: true' localhost:5000/notes            # the fragment
curl -i -H 'Accept: image/png' localhost:5000/notes           # 406 problem
curl -i -H 'Content-Type: text/plain' -d hi localhost:5000/notes   # 415
curl -i -H 'Accept: image/png' localhost:5000/health          # 200, not negotiated
```

## API

- `GET /notes/` - the notes: an HTML page, an htmx fragment, or JSON
- `POST /notes/` - add a note from a form or JSON (`{"text": "..."}`)
- `GET /notes/{id}` - one note, HTML or JSON; 404 in the same type
- `GET /health` - `ok`, never negotiated

`/notes` and `/notes/` both reach the list.

## See also

- `PAGI::ContentNegotiation` - `respond_to`, `negotiated_type`,
  `content_negotiation`
- `PAGI::Middleware::ContentNegotiation` - the options, the scope record, and
  where to declare it
- `PAGI::Tools::Cookbook`, "Vary on a request header you branch on"
- `examples/gut-check/08-negotiation.pl` - the smallest version, side by
  side with Starlette
