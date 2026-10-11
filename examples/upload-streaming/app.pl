#!/usr/bin/env perl
#
# Streaming uploads: bytes or text.
#
#   - Files (archives, images, anything binary) are bytes. body_stream without
#     decode hands them over exactly as sent; nothing is decoded or replaced.
#   - Text is decoded as it streams with decode => $charset. strict decides
#     what happens to bytes that are not valid in that charset: off (the
#     default) turns them into U+FFFD, fine where a garbled character does not
#     matter; on answers the client 400, right where the text is stored or
#     acted on -- and a binary file posted to a text route fails at once
#     instead of becoming garbage text. A charset that cannot be streamed is
#     the client's 415.
#   - A client that hangs up mid-upload is reported by $stream->truncated.
#
# Run:  pagi-server --app examples/upload-streaming/app.pl --port 5000
# Try:  curl -i -T archive.zip localhost:5000/files/archive.zip
#       curl -i --data-binary @people.csv -H 'Content-Type: text/csv; charset=windows-1252' localhost:5000/import
#       curl -i --data-binary 'hello wörld' -H 'Content-Type: text/plain; charset=utf-8' localhost:5000/shout

use v5.40;
use Future::AsyncAwait;
use Digest::SHA;
use Encode qw(encode);
use File::Temp qw(tempdir);
use PAGI::Tools qw(compose response route);

# Bytes: stored exactly as sent, checksummed, size-capped. The name allows
# letters, digits, '-', '_' and single dots between them: no '/', no '..'.
async sub store_file ($request)
{
    my $name = $request->path_param('name');
    my $path = $request->state->get('uploads') . "/$name";
    my $body = $request->body_stream(max_bytes => 50 * 1024 * 1024);
    my $stored = eval { await $body->stream_to_file($path); 1 };
    if (!$stored || $body->truncated || !$body->bytes_read) {
        unlink $path;    # a partial or empty file is not kept
        die $@ unless $stored;    # over max_bytes (the client's 413), or a write failure
        return response('Text', 'The upload was empty or cut short.', status => 400);
    }
    my $sha = Digest::SHA->new(256)->addfile($path)->hexdigest;
    return response('JSON', { name => $name, bytes => $body->bytes_read, sha256 => $sha }, status => 201);
}

# Text, strict: every row is stored, so bad bytes are the client's 400.
async sub import_csv ($request)
{
    my $text = $request->body_stream(decode => $request->charset // 'UTF-8', strict => 1);
    my ($rows, $tail, $started) = (0, '', 0);
    while (defined(my $chunk = await $text->next_chunk)) {
        if (!$started && length $chunk) {    # a UTF-8 BOM (Excel's "CSV UTF-8") is text: drop it
            $chunk =~ s/\A\x{FEFF}//;
            $started = 1;
        }
        $tail .= $chunk;
        $rows++ while $tail =~ s/\A[^\n]*\n//;    # one complete line at a time
    }
    return response('Text', 'The upload was cut short.', status => 400) if $text->truncated;
    $rows++ if length $tail;
    return response('JSON', { rows => $rows });
}

# Text, lenient: a transformation where a stray U+FFFD does no harm.
async sub shout ($request)
{
    my $text = $request->body_stream(decode => $request->charset // 'UTF-8');
    return response('Stream', async sub ($writer) {
        while (defined(my $chunk = await $text->next_chunk)) {
            await $writer->write(encode('UTF-8', uc $chunk));
        }
    }, content_type => 'text/plain; charset=utf-8');
}

compose(
    routes => [
        route('/files/{name:[\w-]+(?:\.[\w-]+)*}' => \&store_file, methods => 'PUT'),
        route('/import' => \&import_csv, methods => 'POST'),
        route('/shout'  => \&shout,      methods => 'POST'),
    ],
    lifespan => {
        startup => sub ($state, $scope) { $state->{uploads} = tempdir(CLEANUP => 1) },
    },
);
