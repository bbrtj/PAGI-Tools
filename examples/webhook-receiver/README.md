# Webhook Receiver

A whip-it-up application: GitHub-style webhook deliveries, verified by HMAC
over the raw body, appended to a JSONL log, with a status page and a JSON
view of the log. The kind of thing you write in one sitting because a
service needs somewhere to post to this afternoon.

It was written cold against the PAGI-Tools docs with a clock running, as
part of the whipupitude gap analysis, and kept as written (one bug fixed:
`use v5.40` turns on the `bitwise` feature, so string xor is `^.`). The
same program in Flask and in Go's `net/http` is in `compare/`, driven with
the same curl sequence.

## Run

```bash
WEBHOOK_SECRET=s3cret pagi-server --app examples/webhook-receiver/app.pl --port 5000
```

The log defaults to `/tmp/deliveries.jsonl`; set `WEBHOOK_LOG` to move it.

## What it shows

- **The raw body is still there after parsing.** `$request->body` caches the
  bytes, and `$request->json` reads through it, so the signature is checked
  on exactly what was sent and the payload is parsed from the same bytes.
- **Bad input answers itself.** A body that is not JSON is a
  `PAGI::Request::BodyError`, which Compose's error handler turns into a
  plain-text 400 with `Cache-Control: no-store`; the handler has no
  try/catch. `GET /hooks/github` is the router's 405 with `Allow: POST`.
- **No ceremony for the page.** The status page is an HTML heredoc in a
  `response('HTML', ...)`; the JSON view is `response('JSON', \@rows)`.
- **In-process tests need no server.** `t/example-webhook-receiver.t` posts
  signed and unsigned deliveries through `PAGI::Test::Client`, whose calls
  return the response directly.

Measured with the gut-check line counter (code lines, imports in
parentheses): PAGI-Tools 53 (5), Flask 47 (2), Go 93 (2). All three answer
the curl sequence below with the same statuses.

## Try

```bash
body='{"action":"opened","number":7}'
sig=$(printf '%s' "$body" | openssl dgst -sha256 -hmac s3cret | sed 's/^.* //')
curl -i -X POST localhost:5000/hooks/github -H 'X-GitHub-Event: pull_request' \
     -H "X-Hub-Signature-256: sha256=$sig" -H 'Content-Type: application/json' -d "$body"   # 202
curl -i -X POST localhost:5000/hooks/github -d "$body"                                        # 401
curl -i localhost:5000/hooks/github                                                           # 405
curl localhost:5000/                                                                          # the page
curl 'localhost:5000/deliveries.json?n=5'
```

## See also

- `PAGI::Request`, `body` and `json`
- `PAGI::Middleware::ErrorHandler`, for what a thrown `BodyError` becomes
- `examples/background-tasks`, for a receiver that does its work after the 202
