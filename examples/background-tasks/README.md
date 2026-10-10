# Background Tasks Example

Work the client does not wait for, three ways: started now, alongside the
response; started once the response has been delivered; or quick bookkeeping
done inline.

Every route is an ordinary handler. Work it starts and does not await belongs
to a `PAGI::FutureOwner`, which reports failures and lets shutdown wait for
it:

```perl
my $background = PAGI::FutureOwner->new(
    on_failure => sub { warn "Background task failed: $_[0]" },
);

async sub signup {
    my ($request) = @_;
    my $data = await $request->json;
    $request->connection->on_complete(sub {
        $background->adopt(send_welcome_email($data->{email}));
    });
    return response('JSON', { status => 'created' }, status => 201);
}

compose(routes => [
    route('/signup' => \&signup, methods => ['POST']),
    ...
], lifespan => {
    shutdown => async sub { await $background->settled },
});
```

## Run

```bash
pagi-server --app examples/background-tasks/app.pl --port 5000
```

Watch the server console for background task output.

## Patterns

### 1. Start now

Begin the work in the handler and hand its Future to `$background`. It runs
alongside the response, so it may still be running, or may already be done,
when the client gets its answer:

```perl
$background->adopt(log_to_analytics('page_view', { path => '/' }));
return response('JSON', { status => 'ok' });
```

### 2. After the response

Register the work on the connection's `on_complete`. It starts once the
response has been delivered; a client that disconnects first does not trigger
it, so it gets no email:

```perl
$request->connection->on_complete(sub {
    $background->adopt(send_welcome_email($email));
});
return response('JSON', { status => 'created' }, status => 201);
```

`on_complete` means "delivered", whatever the status: a handler that
registers it and then dies still delivers a 500, and the work still starts.
Register it just before returning, after anything that can fail. For cleanup
that must run however the connection ends, use `on_end`.

### 3. Quick sync work

For very fast bookkeeping, call it in the handler before returning. It delays
the response by however long it takes, and a blocking call here blocks every
request.

### Start now, or after the response?

- **Start now** when the work does not depend on the client getting its
  answer and starting early helps: analytics, cache warming, logging.
- **After the response** when the work only makes sense once the client has
  the response: a welcome email for a signup that succeeded, a notification
  that a change was accepted.

### Blocking or CPU-heavy work

These patterns are for asynchronous work. Blocking or CPU-heavy work belongs
in another process: `examples/process-streaming` runs one through
`Future::IO`, without naming an event loop.

## Endpoints

- `GET /async` - analytics started now, alongside the response
- `POST /signup` - analytics started now; the welcome email after the response
- `WS /ws` - WebSocket replies, with background analytics per message
