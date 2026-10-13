package NotesApp::Watch;

# A WebSocket endpoint: a fresh object per connection, so what one hook
# leaves for the next (how many messages this connection was sent) lives
# on $self. Clients send {"op":"list"} or {"op":"add","text":"..."}.

use v5.40;
use Moo;
use Future::AsyncAwait;

extends 'PAGI::Endpoint::WebSocket';

sub encoding { 'json' }

# The builder runs once per connection. It gets the connection's
# PAGI::Request (headers, cookies, state), not the WebSocket: only the
# handlers below accept, send and close.
sub BUILD_APP ($class, %args) {
    return sub ($request) { $class->new(%args) };
}

# Configuration, from endpoint().
has greeting => (is => 'ro', default => 'hello');

# This connection's state.
has delivered => (is => 'rw', default => 0);

sub store ($self, $websocket) { $websocket->state->get('notes') }

async sub on_connect ($self, $websocket) {
    await $websocket->accept;
    await $self->reply($websocket, { type => 'hello', greeting => $self->greeting });
}

async sub on_receive ($self, $websocket, $data) {
    my $op = $data->{op} // '';
    if ($op eq 'list') {
        await $self->reply($websocket, { type => 'notes', notes => $self->store($websocket)->all });
    }
    elsif ($op eq 'add') {
        my $note = $self->store($websocket)->add($data->{text}, 'watcher');
        await $self->reply($websocket, { type => 'added', note => $note });
    }
    else {
        await $self->reply($websocket, { type => 'error', message => "unknown op '$op'" });
    }
}

async sub reply ($self, $websocket, $message) {
    $self->delivered($self->delivered + 1);
    await $websocket->send_json({ %$message, delivered => $self->delivered });
}

sub on_disconnect ($self, $websocket, @) {
    $self->store($websocket)->log_watch($self->delivered);
}

1;
