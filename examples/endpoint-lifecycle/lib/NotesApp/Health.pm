package NotesApp::Health;

# A singleton by the author's choice: no BUILD_APP, so endpoint() builds
# it once, with ->new and endpoint()'s arguments. A missing version fails
# there, when app.pl loads, not on a request. Sharing is the
# point here: the hit counter is on the one object (one per worker).

use v5.40;
use Moo;
use Future::AsyncAwait;
use PAGI::Tools qw(response);

extends 'PAGI::Endpoint::HTTP';

has version => (is => 'ro', required => 1);
has hits    => (is => 'rw', default => 0);

async sub get ($self, $request) {
    $self->hits($self->hits + 1);
    return response('JSON', { status => 'ok', version => $self->version, hits => $self->hits });
}

1;
