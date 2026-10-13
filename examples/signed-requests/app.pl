#!/usr/bin/env perl
#
# Requests signed by a CI system, checked by a middleware before any route
# sees them: a build event read with $request->json, and a build artifact
# streamed to disk with body_stream. To check a signature the middleware
# reads the whole body, so it reads through record_receive and hands the
# routes a receive that delivers the body again. Bodies up to 1MB are held
# in memory meanwhile, larger ones in a temporary file.
#
# The signature is an HMAC-SHA256, with the shared secret, of the body's
# SHA-256 (as AWS signs a payload's hash), so the middleware hashes the body
# as it arrives and never holds it in one string.
#
# Run:  SIGNING_SECRET=s3cret pagi-server --app examples/signed-requests/app.pl --port 5000
# Try:  sign() { openssl dgst -sha256 | sed 's/^.* //' | tr -d '\n' \
#                | openssl dgst -sha256 -hmac s3cret | sed 's/^.* /sha256=/'; }
#       body='{"build":42,"status":"passed"}'
#       curl -i localhost:5000/signed/events -H "X-Signature: $(printf '%s' "$body" | sign)" \
#            -H 'Content-Type: application/json' -d "$body"
#       head -c 5000000 /dev/urandom > build.tar
#       curl -i localhost:5000/signed/artifacts/build.tar -H "X-Signature: $(sign < build.tar)" \
#            --data-binary @build.tar
#       curl -i localhost:5000/signed/events -d "$body"     # 401: not signed
#       curl localhost:5000/events

use v5.40;
use Future::AsyncAwait;
use Digest::SHA ();
use File::Temp qw(tempdir);
use PAGI::Tools qw(compose middleware mount response route);
use PAGI::Utils::ReceiveBuffer::TempFile;

package SignedRequests::VerifySignature {
    use parent 'PAGI::Middleware';
    use Future::AsyncAwait;
    use Digest::SHA qw(hmac_sha256_hex);
    use PAGI::Tools qw(response record_receive);
    use PAGI::Utils::SecureCompare qw(secure_compare);

    # secret: the shared secret. buffer: a coderef making each request's
    # buffer; without one, record_receive's default (64KB in memory).
    sub _init ($self, $config) {
        $self->{secret} = $config->{secret} // die "VerifySignature needs a secret\n";
        $self->{buffer} = $config->{buffer};
        $self->{refuse} = response('JSON', { error => 'bad signature' }, status => 401)->to_app;
    }

    sub wrap ($self, $app) {
        return async sub ($scope, $receive, $send) {
            return await $app->($scope, $receive, $send) unless $scope->{type} eq 'http';

            # Read the body through $reading, hashing each chunk; the routes
            # get $replaying, which delivers the same chunks again.
            my ($reading, $replaying) = record_receive($receive,
                $self->{buffer} ? (buffer => $self->{buffer}->($scope)) : ());
            my $sha = Digest::SHA->new(256);
            while (1) {
                my $event = await $reading->();
                return if $event->{type} eq 'http.disconnect';    # nobody to answer
                $sha->add($event->{body} // '');
                last unless $event->{more};
            }

            my ($given) = map { $_->[1] } grep { lc($_->[0]) eq 'x-signature' } @{$scope->{headers}};
            my $want = 'sha256=' . hmac_sha256_hex($sha->hexdigest, $self->{secret});
            my $target = defined($given) && secure_compare($given, $want) ? $app : $self->{refuse};
            await $target->($scope, $replaying, $send);
        };
    }
}

my $SECRET = $ENV{SIGNING_SECRET} // 's3cret';

# A build event: read by PAGI::Request from the replay, like any body.
async sub record_event ($request) {
    my $event = await $request->json;    # a 400 if it is not JSON
    push $request->state->get('events')->@*, $event;
    return response('JSON', { ok => 1, build => $event->{build} }, status => 202);
}

# A build artifact: streamed from the replay to disk. Its SHA-256 is the
# one the signature covered, byte for byte.
async sub store_artifact ($request) {
    my $path = $request->state->get('artifacts') . '/' . $request->path_param('name');
    my $body = $request->body_stream(max_bytes => 50 * 1024 * 1024);
    await $body->stream_to_file($path);
    my $sha = Digest::SHA->new(256)->addfile($path)->hexdigest;
    return response('JSON', { bytes => $body->bytes_read, sha256 => $sha }, status => 201);
}

compose(
    routes => [
        mount('/signed',
            routes => [
                route('/events' => \&record_event, methods => 'POST'),
                route('/artifacts/{name:[\w-]+(?:\.[\w-]+)*}' => \&store_artifact, methods => 'POST'),
            ],
            middleware => [
                middleware(SignedRequests::VerifySignature->new(
                    secret => $SECRET,
                    buffer => sub ($scope) {
                        PAGI::Utils::ReceiveBuffer::TempFile->new(
                            spool_threshold => 1024 * 1024,    # 1MB, then a temp file
                        );
                    },
                )),
            ],
        ),
        route('/events' => sub ($request) { response('JSON', $request->state->get('events')) }),
    ],
    lifespan => {
        startup => sub ($state, $scope) {
            $state->{events}    = [];
            $state->{artifacts} = tempdir(CLEANUP => 1);
        },
    },
);
