package NotesApp::Notes;

# The collection: GET lists one page, POST adds a note by the current user.
# A Moo class built per request by its own builder, which pulls what this
# object needs out of the request (who is asking) and hands it over as an
# attribute; the request itself stays an argument to the handlers.

use v5.40;
use Moo;
use Future::AsyncAwait;
use PAGI::Tools qw(path_for response);

extends 'PAGI::Endpoint::HTTP';

# Called once, by endpoint(), with its arguments. The coderef it returns
# runs for every request and builds the object that answers it.
sub BUILD_APP ($class, %args) {
    return sub ($request) {
        $class->new(%args, current_user => $request->header('X-User') // 'anonymous');
    };
}

# Configuration, from endpoint(): the same value in every request's object.
has page_size => (is => 'ro', default => 20);

# Per request: required, so a builder that forgot it fails loudly.
has current_user => (is => 'ro', required => 1);

sub store ($self, $request) { $request->state->get('notes') }

async sub get ($self, $request) {
    my @notes = $self->store($request)->all->@*;
    splice @notes, $self->page_size if @notes > $self->page_size;
    return response('JSON', \@notes, headers => ['X-Page-Size' => $self->page_size]);
}

async sub post ($self, $request) {
    # The body read is where concurrent requests overlap; each request's
    # current_user is on its own object.
    my $data = await $request->json;
    my $note = $self->store($request)->add($data->{text}, $self->current_user);
    return response('JSON', $note,
        status  => 201,
        headers => [Location => path_for($request, 'note', { id => $note->{id} })],
    );
}

1;
