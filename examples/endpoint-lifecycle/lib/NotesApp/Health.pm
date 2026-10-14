package NotesApp::Health;

# Shared on purpose: BUILD_APP returns one object, built when app.pl loads,
# and that object answers every request, so the hit counter counts them all
# (one per worker). A missing version fails there, at load. Without BUILD_APP
# each request would get a fresh object and a count of 1.

use v5.40;
use Moo;
use Future::AsyncAwait;
use PAGI::Tools qw(response);

extends 'PAGI::Endpoint::HTTP';

sub BUILD_APP ($class, %args) { $class->new(%args) }

has version => (is => 'ro', required => 1);
has hits    => (is => 'rw', default => 0);

async sub get ($self, $request) {
    $self->hits($self->hits + 1);
    return response('JSON', { status => 'ok', version => $self->version, hits => $self->hits });
}

1;
