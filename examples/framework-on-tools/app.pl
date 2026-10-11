#!/usr/bin/env perl
#
# A notes service written against Tiny, the small framework in lib/, to see
# what a framework built on PAGI-Tools looks like from the application side.
# Everything Sinatra, Flask or FastAPI users expect is here: verbs, a merged
# `param`, plain-value returns, a startup-built service, a typed path
# parameter, an exception mapped to a response, a plugin, request
# middleware with call_next, and an OpenAPI document. Plus the raw PAGI
# escape hatch, which none of those have.
#
# Run:  pagi-server --app examples/framework-on-tools/app.pl --port 5000
# Try:  curl -i localhost:5000/notes
#       curl -i -X POST localhost:5000/notes -H 'Content-Type: application/json' -d '{"text":"buy milk"}'
#       curl -i localhost:5000/notes/1
#       curl -i localhost:5000/notes/9            # 404 from a thrown Note::NotFound
#       curl -i localhost:5000/notes/x            # 404 from the Int constraint
#       curl -i localhost:5000/admin              # 403 from the before hook
#       curl -i 'localhost:5000/admin?token=letmein'
#       curl -i localhost:5000/raw                # the escape hatch
#       curl -s localhost:5000/openapi.json | python3 -m json.tool

use v5.40;
use File::Basename qw(dirname);
use lib dirname(__FILE__) . '/lib';
use Future::AsyncAwait;
use Types::Standard qw(Int);
use Tiny;

package Note::NotFound { sub new ($class, $id) { bless { id => $id }, $class } sub id ($self) { $self->{id} } }

# A service: built once at startup, read with $req->svc('notes').
service notes => sub ($state) {
    return { next => 1, by_id => {} };
};

# A plugin: Server-Timing on every response.
plugin 'Timing', name => 'notes';

# Request middleware, Starlette style: call_next, then edit the response.
around async sub ($req, $next) {
    my $sent = await $next->();
    $sent->headers->set('X-Powered-By', 'Tiny on PAGI-Tools');
    return $sent;
};

# A before hook: return a value to answer early, nothing to continue.
before sub ($req) {
    return if $req->path ne '/admin';
    return if ($req->param('token') // '') eq 'letmein';
    return response('JSON', { error => 'forbidden' }, status => 403);
};

# An exception from anywhere becomes this answer.
on_error 'Note::NotFound' => sub ($req, $exc) {
    return response('JSON', { error => 'no such note', id => $exc->id }, status => 404);
};

sub find_note ($req, $id) {
    return $req->svc('notes')->{by_id}{$id} // die Note::NotFound->new($id);
}

# Handlers return plain values: a hashref or arrayref is JSON, a string is HTML.
get '/' => sub ($req) {
    return '<h1>Tiny notes</h1><p>See <a href="/notes">/notes</a> and <a href="/openapi.json">/openapi.json</a>.</p>';
};

get '/notes' => name => 'notes', desc => 'List the notes', sub ($req) {
    my $notes = $req->svc('notes')->{by_id};
    return [ map { $notes->{$_} } sort { $a <=> $b } keys %$notes ];
};

post '/notes' => desc => 'Add a note', async sub ($req) {
    my $data  = await $req->json;
    my $notes = $req->svc('notes');
    my $id    = $notes->{next}++;
    $notes->{by_id}{$id} = { id => $id, text => $data->{text} };
    return response('JSON', $notes->{by_id}{$id}, status => 201);
};

get '/notes/{id}' => name => 'note', desc => 'One note', constraints => { id => Int }, sub ($req) {
    return find_note($req, $req->param('id'));
};

del '/notes/{id}' => constraints => { id => Int }, sub ($req) {
    find_note($req, $req->param('id'));
    delete $req->svc('notes')->{by_id}{ $req->param('id') };
    return response('Empty');
};

get '/admin' => sub ($req) { { admin => 'ok' } };

# The OpenAPI document, generated from the Router the framework composes.
get '/openapi.json' => openapi(title => 'Tiny notes');

# The escape hatch: a raw PAGI application on a route, for when the
# framework's request/response model is in the way (here: a hand-rolled
# chunked body, which a Response value cannot express without a Stream).
raw '/raw' => async sub ($scope, $receive, $send) {
    await $send->({ type => 'http.response.start', status => 200,
        headers => [['content-type', 'text/plain']] });
    await $send->({ type => 'http.response.body', body => "raw ", more => 1 });
    await $send->({ type => 'http.response.body', body => "PAGI\n" });
};

tiny;
