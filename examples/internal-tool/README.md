# Internal Tool

A task board for a small team: the everyday HTML workflow every web
framework is judged on. Pages come from templates, the add form re-renders
with its errors and what was typed, a good submission redirects and the next
page shows a flash message, every form carries a CSRF token, and the
stylesheet comes from a static directory.

PAGI-Tools ships no template engine, flash or validation. This app shows
what each costs on top of it. The same application in Flask, which has all
three built in, is in `compare/`; it was driven with the same requests and
answers them the same way.

## Run

```bash
pagi-server --app examples/internal-tool/app.pl --port 5000
```

Then open http://localhost:5000/. Template Toolkit (`Template`) must be
installed; it is not a dependency of PAGI-Tools.

## What it shows

- **Templates.** `Template->new(INCLUDE_PATH => ...)` renders into a string
  and `response('HTML', $html)` sends it; the `page` helper adds the CSRF
  token, the flash and a `url` function (`path_for`) to every render. Ten
  lines, written once.
- **Redirect after POST.** `response('Redirect', path_for($request, 'index'),
  status => 303)`.
- **Flash.** Two lines on the session: `set(flash => ...)` in the POST
  handler, `get`-then-`delete` in `page`.
- **Validation errors.** Hand-written: a `validate` returning values and
  errors, and a 422 re-render of the same template.
- **CSRF on forms.** The middleware runs with `session => 1, refuse => 0`
  because the token is a form field it does not read, so each POST handler
  calls `csrf($request)->verify` on the parsed field. A missing token is a
  403.
- **Static files.** `mount('/static', app =>
  PAGI::App::File->from_app_path('public'))`. No route names a mount, so
  the stylesheet link is built from `root_path` by hand.
- **State at startup.** The board lives in lifespan state and is read with
  `app_state($request)`.

Measured with the gut-check line counter (code lines, imports in
parentheses): PAGI-Tools 83 (9), Flask 51 (2). The templates are 47 and 44
lines. The difference is the batteries: Flask's `render_template`,
`flash`/`get_flashed_messages` and `url_for('static', ...)` are the `page`,
`flash` and `static` helpers here, and Flask's module-level `BOARD` is
Compose's `lifespan` block.

## Try

```bash
curl -c jar -b jar localhost:5000/                      # the board, with a csrf_token field
tok=...                                                  # copy it from the form
curl -c jar -b jar -X POST localhost:5000/tasks --data-urlencode 'title=' \
     --data-urlencode "csrf_token=$tok"                  # 422, re-rendered with errors
curl -c jar -b jar -X POST localhost:5000/tasks --data-urlencode 'title=Rotate the key' \
     --data-urlencode "csrf_token=$tok" -i               # 303 to /
curl -c jar -b jar localhost:5000/                      # the flash, then the task
curl -c jar -b jar -X POST localhost:5000/tasks/1/toggle --data-urlencode "csrf_token=$tok" -i
curl -i localhost:5000/static/style.css
```

## See also

- `PAGI::Session` and `PAGI::Middleware::Session`
- `PAGI::CSRF`, for `verify` with a form-field token
- `PAGI::App::File`, `from_app_path`
- `examples/auth-cookie-login`, the same form idioms with a login
- `examples/contact-form`, form fields and file uploads without a session
