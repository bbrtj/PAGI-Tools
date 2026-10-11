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
# A stream gives bytes, so relay and sha256 take any upload, a zip included.
# shout reads its body as text, so it asks for chunks decoded by the charset
# the client declared (UTF-8 when it declares none), and a character split
# across two chunks still arrives whole. Python's bytes.upper() only knows
# ASCII; this shouts "café" as "CAFÉ".
#
# Run:  pagi-server --app examples/gut-check/07-upload-relay.pl --port 5000
# Try:  curl -s --data-binary @/usr/share/dict/words localhost:5000/sha256
#       curl -s --data-binary 'café' localhost:5000/shout
#       printf 'caf\xe9' | curl -s --data-binary @- \
#           -H 'Content-Type: text/plain; charset=ISO-8859-1' localhost:5000/shout

use v5.40;
use Future::AsyncAwait;
use Digest::SHA;
use Encode qw(encode);
use PAGI::Tools qw(compose response route);

async sub relay ($request) {
    my $body = $request->body_stream;
    return response('Stream', async sub ($writer) { await $writer->pipe_from($body) });
}

async sub shout ($request) {
    my $text = $request->body_stream(decode => $request->charset // 'UTF-8');
    return response('Stream', async sub ($writer) {
        while (defined(my $chunk = await $text->next_chunk)) {
            await $writer->write(encode('UTF-8', uc $chunk));
        }
    }, content_type => 'text/plain; charset=utf-8');
}

async sub sha256 ($request) {
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
