# Signed requests

A CI system posts build events and build artifacts, each signed with a
shared secret. A middleware checks every signature before a route runs; the
routes then read the same bodies the middleware read: an event with
`$request->json`, an artifact streamed to disk with `body_stream`.

Requires Perl 5.40.

```
SIGNING_SECRET=s3cret pagi-server --app examples/signed-requests/app.pl --port 5000
```

The comment at the top of `app.pl` has `curl` commands that sign a JSON
event and a 5MB artifact, and one that is refused.

## A middleware that reads the body

A request body can be received only once. To check a signature, the
middleware must read the whole body before the route runs, and the route
must still receive it. Passing on the `$receive` the middleware read from
would leave the route nothing: on a real server its next receive waits for
a disconnect that never comes.

`record_receive` (from `PAGI::Utils::Middleware`, or `PAGI::Tools`) solves
this:

```perl
my ($reading, $replaying) = record_receive($receive);
# ... read the body through $reading ...
await $app->($scope, $replaying, $send);
```

`$reading` keeps every event it delivers; `$replaying` delivers them again,
in order, then continues with the live receive. The route cannot tell the
difference: `json`, `body`, `body_stream` and a hand-written receive loop all
see the body as the client sent it. The test (`t/example-signed-requests.t`)
stores a 2MB artifact and checks its SHA-256 against what was signed.

The refusal gets `$replaying` too, as every application the middleware
calls should.

## Where the body waits

Between the check and the route, the body has to be kept somewhere. By
default `record_receive` uses a `PAGI::Utils::ReceiveBuffer::TempFile`,
which holds 64KB in memory and spools the rest to a temporary file with no
name, so it is gone when the request is. This middleware takes a `buffer`
option, a coderef that makes each request's buffer, and the application
raises the threshold to 1MB:

```perl
buffer => sub ($scope) {
    PAGI::Utils::ReceiveBuffer::TempFile->new(spool_threshold => 1024 * 1024);
},
```

A buffer is any object with `append` and `take` methods returning Futures,
so one that keeps bodies in Redis, or writes with IO::AIO, drops in the same
way. `TempFile`'s own file writes block, as `PAGI::Request`'s upload
spool does: a loop-agnostic module has no asynchronous way to write a
regular file.

## Notes

- The signature is an HMAC of the body's SHA-256, as AWS signs a payload's
  hash, so the middleware hashes each chunk as it arrives and never holds
  the body in one string. GitHub's scheme, an HMAC over the body itself,
  needs an incremental HMAC (`Digest::HMAC`), which is not in core Perl.
- The whole body is read before the route starts, so a large artifact
  finishes uploading before it is written to its final place. That is the
  cost of checking first; the buffer is what keeps it off the heap.
- Everything under `/signed` must be signed: a `GET` there is a 401, not a
  405, because the middleware answers before the router does.
- `PAGI::Middleware::CSRF` does the same when it reads a form's token: see
  `WRITING MIDDLEWARE` in `PAGI::Middleware`.
