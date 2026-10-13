package NotesApp::Note;

# One note: GET and DELETE. Plain Perl, a fresh object per request, so the
# note looked up once can be kept on $self for the rest of the request.

use v5.40;
use parent 'PAGI::Endpoint::HTTP';
use Future::AsyncAwait;
use PAGI::Tools qw(response);

sub BUILD_APP ($class, %args) {
    return sub ($request) { $class->new(%args) };
}

sub store ($self, $request) { $request->state->get('notes') }

sub note ($self, $request) {
    $self->{note} //= $self->store($request)->find($request->path_param('id'));
}

async sub get ($self, $request) {
    my $note = $self->note($request)
        or return response('JSON', { error => 'no such note' }, status => 404);
    return response('JSON', $note);
}

async sub delete ($self, $request) {
    my $note = $self->note($request)
        or return response('JSON', { error => 'no such note' }, status => 404);
    $self->store($request)->remove($note->{id});
    return response('Empty');
}

1;
