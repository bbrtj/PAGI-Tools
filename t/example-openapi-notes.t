use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use lib "$Bin/../examples/openapi-notes/lib";
use PAGI::Test::Client;

# examples/openapi-notes: the API works, and the document it serves is the
# one its routes describe.

BEGIN { plan skip_all => 'examples/openapi-notes requires Perl 5.40' if $] < 5.040 }

require NotesApp;
my $client = PAGI::Test::Client->new(app => NotesApp->new->to_app);
my %as = map { $_ => { Authorization => "Bearer $_" } } qw(reader writer);

subtest 'the API' => sub {
    is($client->get('/notes/')->json, [], 'no notes yet');
    my $res = $client->post('/notes/', headers => $as{writer}, json => { text => 'buy milk' });
    is([$res->status, $res->json], [201, { id => 1, text => 'buy milk' }], 'a writer adds one');
    is($client->post('/notes/', headers => $as{reader}, json => { text => 'no' })->status, 403, 'a reader may not');
    is($client->post('/notes/', json => { text => 'no' })->status, 403, 'nor a guest');
    is($client->get('/notes/1')->json, { id => 1, text => 'buy milk' }, 'it is shown');
    is([$client->get('/notes/9')->status, $client->get('/notes/9')->json], [404, { error => 'No such note' }], 'a missing one');
    is($client->get('/notes/x')->status, 404, 'a non-integer id matches no route');
    is($client->delete('/notes/1', headers => $as{writer})->status, 204, 'a writer deletes it');
    is($client->get('/notes/1')->status, 404, 'and it is gone');
    like($client->get('/static/index.html')->text, qr{/openapi\.json}, 'the static page is served');
};

subtest 'the document' => sub {
    my $id = { name => 'id', in => 'path', required => T(), schema => { type => 'integer' } };
    my $json = sub { my ($description, $schema) = @_; return { description => $description, content => { 'application/json' => { schema => $schema } } } };
    my $ref = sub { return { '$ref' => "#/components/schemas/$_[0]" } };
    my $writers = [{ bearer => ['notes:write'] }];
    is($client->get('/openapi.json')->json, {
        openapi => '3.1.0',
        info    => { title => 'Notes', version => '1.0.0' },
        paths   => {
            '/notes/' => {
                get => { operationId => 'get_notes_list', summary => 'List the notes',
                    responses => { 200 => $json->('Every note', { type => 'array', items => $ref->('Note') }) } },
                post => { operationId => 'post_notes_create', summary => 'Add a note', security => $writers,
                    requestBody => { required => T(), content => { 'application/json' => { schema => $ref->('NewNote') } } },
                    responses => { 201 => $json->('The new note', $ref->('Note')) } },
            },
            '/notes/{id}' => {
                get => { operationId => 'get_notes_show', summary => 'One note', parameters => [$id],
                    responses => { 200 => $json->('The note', $ref->('Note')), 404 => $json->('No such note', $ref->('Error')) } },
                delete => { operationId => 'delete_notes_remove', summary => 'Delete a note', parameters => [$id],
                    security => $writers,
                    responses => { 204 => { description => 'Deleted' }, 404 => $json->('No such note', $ref->('Error')) } },
            },
        },
        components => {
            schemas         => NotesApp::Notes->schemas,
            securitySchemes => { bearer => { type => 'http', scheme => 'bearer' } },
        },
    }, 'exactly the routes, typed, with security from Requires; no /static, no /openapi.json');
};

done_testing;
