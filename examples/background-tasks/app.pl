#!/usr/bin/env perl
#
# Background Tasks Example
#
# Work the client does not wait for, three ways:
#   1. Start now      - begin async work in the handler and hand its Future to
#                       a PAGI::FutureOwner; it runs alongside the response.
#   2. After response - register it on the connection's on_complete; it starts
#                       once the response has been delivered.
#   3. Quick sync     - tiny bookkeeping done inline before returning.
#
# The owner is built at lifespan startup and lives in the application state,
# like any other long-lived thing a handler reaches for; shutdown waits for
# the work it still holds. An owner is not a queue: the work starts the
# moment the async sub is called, and adopt only holds its Future until it
# settles, reports a failure, and lets shutdown wait.
#
# What this is not: durable. This is best-effort, in-process work, per
# worker. A crash, restart or deploy loses it; shutdown waits only as long
# as the server's shutdown timeout allows; there is no concurrency cap and
# no retry. Work that must happen belongs in a durable job queue (Minion in
# Perl; Celery, RQ or Sidekiq elsewhere; Starlette's BackgroundTasks has the
# same limits as this file), and the handler only enqueues it.
#
# Blocking or CPU-heavy work belongs in another process; see
# examples/process-streaming for a subprocess driven through Future::IO.
#
# Run: pagi-server --app examples/background-tasks/app.pl --port 5000
#
# Test:
#   curl http://localhost:5000/async
#   curl -X POST http://localhost:5000/signup -d '{"email":"test@example.com"}'
#

use strict;
use warnings;
use Future::AsyncAwait;
use Future::IO;    # pagi-server binds the implementation

use PAGI::FutureOwner;
use PAGI::Tools qw(compose response route websocket);

# Simulated async email API (would use an async HTTP client in practice)
async sub send_welcome_email {
    my ($email) = @_;
    warn "[async] Sending welcome email to $email...\n";
    await Future::IO->sleep(2);
    warn "[async] Email sent to $email!\n";
}

# Simulated async analytics API
async sub log_to_analytics {
    my ($event, $data) = @_;
    warn "[async] Logging '$event' to analytics...\n";
    await Future::IO->sleep(1);
    warn "[async] Analytics logged!\n";
}

# PATTERN 3: quick sync work. It runs before the response is returned, so it
# must be fast: a blocking call here blocks every request.
sub quick_sync_task {
    my ($message) = @_;
    warn "[sync] Quick task: $message\n";
}

# PATTERN 1: start now. The work runs alongside the response.
sub async_tasks {
    my ($request) = @_;
    my $background = $request->state->get('background');

    $background->adopt(log_to_analytics('page_view', { path => '/' }));
    quick_sync_task("Logging request");

    return response('JSON', {
        status  => 'ok',
        message => 'Response sent! Analytics running alongside it.',
    });
}

# PATTERN 2: after the response. The email starts once the client has been
# sent its 201; a client that disconnects first gets no email. on_complete
# means "delivered", whatever the status, so it is registered just before
# returning, after anything that could fail.
async sub signup {
    my ($request) = @_;
    my $background = $request->state->get('background');

    my $data = await $request->json;
    my $email = $data->{email} // 'unknown@example.com';

    $background->adopt(log_to_analytics('signup', { email => $email }));
    quick_sync_task("New signup: $email");

    $request->connection->on_complete(sub {
        $background->adopt(send_welcome_email($email));
    });
    return response('JSON', {
        status  => 'created',
        message => "Account created! Check $email for welcome email.",
    }, status => 201);
}

# WebSocket with background processing
async sub messages {
    my ($ws) = @_;
    my $background = $ws->state->get('background');

    await $ws->accept;
    await $ws->send_text('Connected! Send a message.');

    await $ws->each_text(async sub {
        my ($text) = @_;

        # The reply is best-effort: a client that has already gone has
        # nobody to tell, and that is not an error.
        await $ws->try_send_text("Got: $text");

        # Background work is not awaited: $background owns it.
        $background->adopt(log_to_analytics('ws_message', { text => $text }));
    });
}

compose(routes => [

route('/' => sub {
    return response('HTML', <<'HTML');
<!DOCTYPE html>
<html>
<head><title>Background Tasks Demo</title></head>
<body>
<h1>Background Tasks Demo</h1>
<p>Watch the server console for background task output.</p>

<h2>Endpoints</h2>
<ul>
  <li><a href="/async">/async</a> - async work started now, alongside the response</li>
</ul>

<h2>POST /signup</h2>
<p>The welcome email starts after the response has been delivered.</p>
<form id="signup">
  <input type="email" name="email" placeholder="email@example.com" required>
  <button type="submit">Sign Up</button>
</form>
<pre id="result"></pre>

<script>
document.getElementById('signup').onsubmit = async (e) => {
  e.preventDefault();
  const email = e.target.email.value;
  const res = await fetch('/signup', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({email})
  });
  document.getElementById('result').textContent = await res.text();
};
</script>
</body>
</html>
HTML
}),

route('/async'  => \&async_tasks),
route('/signup' => \&signup, methods => ['POST']),
websocket('/ws' => \&messages),
], lifespan => {
    # Work the client does not wait for belongs to this owner, which
    # reports failures and lets shutdown wait for it.
    startup => sub {
        my ($state) = @_;
        $state->{background} = PAGI::FutureOwner->new(
            on_failure => sub { warn "Background task failed: $_[0]" },
        );
    },
    # Work still running finishes before the process exits.
    shutdown => async sub {
        my ($state) = @_;
        await $state->{background}->settled;
    },
});
