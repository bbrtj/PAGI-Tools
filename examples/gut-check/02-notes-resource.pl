#!/usr/bin/env perl
#
# A small REST resource: lifespan builds the store, class-based endpoints
# serve the collection and the item, and links come from route names.
#
# The Starlette version is in README.md.
#
# Run:  pagi-server --app examples/gut-check/02-notes-resource.pl --port 5000
# Try:  curl -i -X POST localhost:5000/notes -d '{"text":"buy milk"}'
#       curl -i localhost:5000/notes/1
#       curl -i -X DELETE localhost:5000/notes/1

use v5.40;
use Future::AsyncAwait;

package NoteStore {
    use v5.40;

    sub new ($class) { bless { next => 1, notes => {} }, $class }
    sub all ($self) { [ map { $self->{notes}{$_} } sort { $a <=> $b } keys $self->{notes}->%* ] }
    sub find ($self, $id) { $self->{notes}{$id} }
    sub add ($self, $data) { my $id = $self->{next}++; $self->{notes}{$id} = { id => $id, text => $data->{text} } }
    sub remove ($self, $id) { delete $self->{notes}{$id} }

    # Startup stores the store once; requests read it through a read-only
    # view of the lifespan state, so no request can replace it.
    sub for_request ($class, $request) { $request->state->get('notes') }
}

package Notes {
    use v5.40;
    use parent 'PAGI::Endpoint::HTTP';
    use Future::AsyncAwait;
    use PAGI::Tools qw(path_for response);

    async sub get ($self, $request) {
        return response('JSON', NoteStore->for_request($request)->all);
    }

    async sub post ($self, $request) {
        my $note = NoteStore->for_request($request)->add(await $request->json);
        return response('JSON', $note,
            status => 201,
            headers => [Location => path_for($request, 'note', { id => $note->{id} })],
        );
    }
}

package Note {
    use v5.40;
    use parent 'PAGI::Endpoint::HTTP';
    use Future::AsyncAwait;
    use PAGI::Tools qw(response);

    async sub get ($self, $request) {
        my $note = NoteStore->for_request($request)->find($request->path_param('id'))
            or return response('JSON', { error => 'no such note' }, status => 404);
        return response('JSON', $note);
    }

    async sub delete ($self, $request) {
        NoteStore->for_request($request)->remove($request->path_param('id'))
            or return response('JSON', { error => 'no such note' }, status => 404);
        return response('Empty');
    }
}

package main;

use PAGI::Tools qw(compose endpoint route);
use Types::Standard qw(Int);

compose(
    routes => [
        route('/notes' => endpoint('Notes'), name => 'notes'),
        route('/notes/{id}' => endpoint('Note'), name => 'note', constraints => { id => Int }),
    ],
    lifespan => {
        startup => sub ($state, $scope) { $state->{notes} = NoteStore->new },
    },
);
