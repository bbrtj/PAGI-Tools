#!/usr/bin/env perl
#
# One notes resource for browsers and API clients. Browsers get HTML pages
# and post a form; API clients get JSON and post JSON. The middleware picks
# the representation from Accept, answers 406, and sends Vary: Accept on
# everything; handlers only say what each representation is.
#
# Run:  pagi-server --app examples/content-negotiation/app.pl --port 5000
# Try:  open http://localhost:5000/notes in a browser and add a note
#       curl -i -H 'Accept: application/json' localhost:5000/notes
#       curl -i -H 'Accept: application/json' -H 'Content-Type: application/json' \
#            -d '{"text":"buy milk"}' localhost:5000/notes
#       curl -i -H 'Accept: image/png' localhost:5000/notes      # 406

use v5.40;
use Future::AsyncAwait;

package NoteStore {
    use v5.40;

    sub new ($class) { bless { next => 1, notes => {} }, $class }
    sub all ($self) { [ map { $self->{notes}{$_} } sort { $a <=> $b } keys $self->{notes}->%* ] }
    sub find ($self, $id) { $self->{notes}{$id} }
    sub add ($self, $data) { my $id = $self->{next}++; $self->{notes}{$id} = { id => $id, text => $data->{text} } }

    sub for_request ($class, $request) { $request->state->get('notes') }
}

package main;

use PAGI::Tools qw(compose middleware negotiated_type path_for respond_to response route);
use Types::Standard qw(Int);

sub esc ($text) { $text =~ s/([&<>"'])/'&#' . ord($1) . ';'/ger }

sub page ($title, $body, %opts)
{
    return response('HTML', "<!doctype html><title>$title</title><h1>$title</h1>$body", %opts);
}

async sub list ($request)
{
    my $notes = NoteStore->for_request($request)->all;
    return respond_to($request,
        html => sub {
            page('Notes', join '',
                '<ul>', (map { '<li>' . esc($_->{text}) . '</li>' } @$notes), '</ul>',
                '<form method="post"><input name="text"><button>Add</button></form>');
        },
        json => sub { response('JSON', $notes) },
    );
}

async sub show ($request)
{
    # The same choice, read directly, where an if reads better than branches.
    # The 404 is returned, not thrown: a returned answer gets the middleware's
    # Vary: Accept, a thrown one goes straight to the error handler.
    my $note = NoteStore->for_request($request)->find($request->path_param('id'))
        or return negotiated_type($request) eq 'json'
            ? response('JSON', { error => 'no such note' }, status => 404)
            : page('Not found', '<p>No such note.</p>', status => 404);

    return respond_to($request,
        html => sub { page('Note', '<p>' . esc($note->{text}) . '</p>') },
        json => sub { response('JSON', $note) },
    );
}

async sub create ($request)
{
    # The body's type decides how to read it (input); Accept decides the
    # answer (output). They are separate questions.
    my $data = $request->is_json ? await $request->json
             : $request->is_form ? { text => (await $request->form_params)->get('text') }
             : return response('Text', 'Unsupported Media Type', status => 415);

    my $note = NoteStore->for_request($request)->add($data);
    my $url  = path_for($request, 'note', { id => $note->{id} });
    return respond_to($request,
        html => sub { response('Redirect', path_for($request, 'notes'), status => 303) },
        json => sub { response('JSON', $note, status => 201, headers => [Location => $url]) },
    );
}

compose(
    routes => [
        route('/notes'      => \&list,   name => 'notes'),
        route('/notes'      => \&create, methods => 'POST'),
        route('/notes/{id}' => \&show,   name => 'note', constraints => { id => Int }),
    ],
    middleware => [
        # Declared once: the types every route here can answer with, most
        # preferred first (a browser sending */* gets HTML).
        middleware('ContentNegotiation', supported_types => ['html', 'json']),
    ],
    lifespan => {
        startup => sub ($state, $scope) { $state->{notes} = NoteStore->new },
    },
);
