#!/usr/bin/env perl
#
# Request bodies as streams: relay an upload straight back, transform it chunk
# by chunk, or checksum it, without ever holding the whole body in memory.
#
# Starlette:
#
#     async def shout(request):
#         async def upper():
#             async for chunk in request.stream():
#                 yield chunk.upper()
#         return StreamingResponse(upper(), media_type="application/octet-stream")
#
# PAGI: $request->body_stream is a pull source, and a Writer can pipe_from it
# (a straight relay) or the producer can pull next_chunk itself (a transform).
#
# Run:  pagi-server --app examples/gut-check/07-upload-relay.pl --port 5000
# Try:  curl -s --data-binary @/usr/share/dict/words localhost:5000/sha256
#       curl -s --data-binary 'hello' localhost:5000/shout

use v5.40;
use Future::AsyncAwait;
use Digest::SHA;
use PAGI::Tools qw(compose response route);

async sub relay ($request)
{
    my $body = $request->body_stream;
    return response('Stream', async sub ($writer) { await $writer->pipe_from($body) });
}

async sub shout ($request)
{
    my $body = $request->body_stream;
    return response('Stream', async sub ($writer) {
        while (defined(my $chunk = await $body->next_chunk)) {
            await $writer->write(uc $chunk);
        }
    });
}

async sub sha256 ($request)
{
    my ($body, $sha) = ($request->body_stream, Digest::SHA->new(256));
    while (defined(my $chunk = await $body->next_chunk)) {
        $sha->add($chunk);
    }
    return response('JSON', { bytes => $body->bytes_read, sha256 => $sha->hexdigest });
}

compose(
    routes => [
        route('/relay' => \&relay, methods => ['POST']),
        route('/shout' => \&shout, methods => ['POST']),
        route('/sha256' => \&sha256, methods => ['POST']),
    ],
);
