package NotesApp::Notes;

# The notes API, a Router from a class method: the application that mounts
# it sees every route, in route_table, path_for and the OpenAPI document. The
# meta on each route is the hand-written part of the document -- request and
# response bodies -- which a generated client turns into typed models.

use v5.40;
use Future::AsyncAwait;
use Types::Standard qw(Int);
use PAGI::Response qw(response);
use PAGI::Routing qw(router route middleware);

# One process's notes: an example, not a store.
my %notes;
my $next_id = 1;

# The schemas the meta below refers to; the root puts them in the document's
# components.
sub schemas ($class) {
    return {
        Note => {
            type => 'object', required => ['id', 'text'],
            properties => { id => { type => 'integer' }, text => { type => 'string' } },
        },
        NewNote => {
            type => 'object', required => ['text'],
            properties => { text => { type => 'string' } },
        },
        Error => {
            type => 'object', required => ['error'],
            properties => { error => { type => 'string' } },
        },
    };
}

sub json_response ($description, $schema) {
    return { description => $description, content => { 'application/json' => { schema => $schema } } };
}
sub ref_to ($name) { return { '$ref' => "#/components/schemas/$name" } }

my $missing = json_response('No such note', ref_to('Error'));

sub routing ($class) {
    my $writers = [middleware('Requires', scopes => ['notes:write'])];
    return router(routes => [
        route('/' => \&list, methods => ['GET'], name => 'list', desc => 'List the notes',
            meta => { openapi => { responses => {
                200 => json_response('Every note', { type => 'array', items => ref_to('Note') }),
            } } }),
        route('/' => \&create, methods => ['POST'], name => 'create', desc => 'Add a note',
            middleware => $writers,
            meta => { openapi => {
                requestBody => { required => \1, content => { 'application/json' => { schema => ref_to('NewNote') } } },
                responses   => { 201 => json_response('The new note', ref_to('Note')) },
            } }),
        route('/{id:&Int}' => \&show, methods => ['GET'], name => 'show', desc => 'One note',
            meta => { openapi => { responses => {
                200 => json_response('The note', ref_to('Note')),
                404 => $missing,
            } } }),
        route('/{id:&Int}' => \&remove, methods => ['DELETE'], name => 'remove', desc => 'Delete a note',
            middleware => $writers,
            meta => { openapi => { responses => {
                204 => { description => 'Deleted' },
                404 => $missing,
            } } }),
    ]);
}

sub list ($request) {
    return response('JSON', [ map { $notes{$_} } sort { $a <=> $b } keys %notes ]);
}

async sub create ($request) {
    my $data = await $request->json;
    my $id   = $next_id++;
    $notes{$id} = { id => $id, text => $data->{text} // '' };
    return response('JSON', $notes{$id}, status => 201);
}

sub show ($request) {
    my $note = $notes{ $request->path_param('id') };
    return $note ? response('JSON', $note) : not_found();
}

sub remove ($request) {
    delete $notes{ $request->path_param('id') } or return not_found();
    return response('Empty');
}

sub not_found () { return response('JSON', { error => 'No such note' }, status => 404) }

1;
