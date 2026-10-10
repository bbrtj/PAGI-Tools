#!/usr/bin/env perl
#
# One hub, three doors: WebSocket clients chat, SSE clients watch, and a plain
# HTTP POST announces to everyone. Starlette users reach for the separate
# `broadcaster` package for this; here it is a few lines of plain Perl,
# because every connection helper has the same best-effort try_send_* family.
#
# Starlette (with the encode/broadcaster package):
#
#     async def chat(websocket):
#         await websocket.accept()
#         async with broadcast.subscribe("room") as sub: ...
#
# Run:  pagi-server --app examples/gut-check/03-broadcast-hub.pl --port 5000
# Try:  websocat ws://localhost:5000/chat
#       curl -N -H 'Accept: text/event-stream' localhost:5000/watch
#       curl -X POST localhost:5000/announce -d 'tea is ready'

use v5.40;
use Future::AsyncAwait;
use Scalar::Util qw(refaddr);
use PAGI::Tools qw(compose response route sse websocket);

# The hub keys listeners by refaddr: never by "$object" inside an async sub
# that suspends (see the PAGI::SSE SYNOPSIS).
my %listeners;

sub listen_to ($id, $deliver) { $listeners{$id} = $deliver }
sub stop_listening ($id) { delete $listeners{$id} }

# Best-effort fan-out: one slow or vanished listener must not stop the rest.
sub publish ($from, $text)
{
    $_->("$from: $text") for values %listeners;
    return scalar keys %listeners;
}

async sub chat ($ws)
{
    my $id = refaddr $ws;
    $ws->on_close(sub { stop_listening($id) });

    await $ws->accept;
    listen_to($id, sub ($line) { $ws->try_send_text($line) });

    await $ws->each_text(async sub ($text) { publish('chat', $text) });
}

async sub watch ($sse)
{
    my $id = refaddr $sse;
    $sse->on_close(sub { stop_listening($id) });

    await $sse->start;
    # Not a send guard: a watcher that already left must not be registered,
    # or its listener would never be removed.
    return if $sse->is_closed;
    listen_to($id, sub ($line) { $sse->try_send_event(event => 'line', data => $line) });

    await $sse->run;
}

async sub announce ($request)
{
    my $count = publish('announce', await $request->text);
    return response('JSON', { delivered_to => $count }, status => 202);
}

compose(
    routes => [
        websocket('/chat' => \&chat),
        sse('/watch' => \&watch),
        route('/announce' => \&announce, methods => ['POST']),
    ],
);
