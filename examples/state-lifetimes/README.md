# State lifetimes

A members list whose application state declares how long each value lives,
instead of building everything at startup:

| Key | Lifetime | Value | Why |
|---|---|---|---|
| `db` | `singleton` | a Future | one connection per worker, opened on first use |
| `members` | `singleton` | a Future | built on `db`, in whatever order they are asked for |
| `viewer` | `per_request` | a Future | who is asking: the access log asks first, the handler gets the same answer |
| `join_form` | `factory` | a Future | each submission gets a clean form, its store wired in |
| `access_log` | plain value | an arrayref | as always |

A value whose builder is async is a Future: `await $request->state->get('viewer')`.
Two requests asking for `db` at once share one connection attempt, and a failed
attempt is tried again by the next request.

Shutdown closes the connection only if a request opened it:

```perl
(await $state->{db}->value)->disconnect if $state->{db}->built;
```

## Running

```bash
cd examples/state-lifetimes
pagi-server -I lib --app lib/MyApp.pm --port 5000
curl http://localhost:5000/
curl --cookie token=ada-token http://localhost:5000/
curl -d name=Grace -d email=grace@example.com http://localhost:5000/join
```

The module runs one request from the command line too:

```bash
perl -I lib lib/MyApp.pm GET /
```
