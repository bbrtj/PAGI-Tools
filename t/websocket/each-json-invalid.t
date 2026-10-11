use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;

use lib 'lib';
use PAGI::Test::Client;
use PAGI::Compose qw(compose);
use PAGI::Routing qw(websocket);

# each_json's policy for a message that is not JSON: close 1007 by default,
# the caller's on_invalid_json in its place, or a subclass's
# handle_invalid_json. The loop ends once the connection is not connected.

# Tools' router builds a PAGI::WebSocket; a framework builds its own
# subclass. Reblessing the routed object stands in for that.
{
    package Local::ReplyingWebSocket;
    use parent -norequire, 'PAGI::WebSocket';
    use Future::AsyncAwait;

    async sub handle_invalid_json {
        my ($self, $text, $error) = @_;
        await $self->send_json({ error => 'subclass says: expected JSON' });
        return;
    }
}

my @log;

async sub echo_json {
    my ($ws, %opts) = @_;
    await $ws->accept;
    await $ws->each_json(async sub {
        my ($data) = @_;
        push @log, "callback $data->{n}";
        await $ws->send_json({ got => $data->{n} });
    }, %opts);
    push @log, 'handler returned';
}

my $client = PAGI::Test::Client->new(app => compose(routes => [
    websocket('/default' => sub { echo_json($_[0]) }),
    websocket('/reply' => sub {
        my ($ws) = @_;
        echo_json($ws, on_invalid_json => async sub {
            await $ws->send_json({ error => 'expected JSON' });
        });
    }),
    websocket('/reply-sync' => sub {
        my ($ws) = @_;
        echo_json($ws, on_invalid_json => sub {
            $ws->try_send_json({ error => 'expected JSON' });
            return;
        });
    }),
    websocket('/raise' => sub {
        my ($ws) = @_;
        echo_json($ws, on_invalid_json => sub { die "bad JSON: $_[1]" });
    }),
    websocket('/subclass' => sub { echo_json(bless $_[0], 'Local::ReplyingWebSocket') }),
    websocket('/dying-callback' => async sub {
        my ($ws) = @_;
        await $ws->accept;
        await $ws->each_json(async sub { die "callback broke\n" });
    }),
]));

subtest 'by default invalid JSON closes 1007 and the handler returns' => sub {
    @log = ();
    my $ws = $client->websocket('/default');
    $ws->send_text('{"n":1}');
    is $ws->receive_json, { got => 1 }, 'valid JSON reaches the callback';
    $ws->send_text('{bad');
    is [$ws->close_code, $ws->close_reason], [1007, 'invalid JSON'];
    is \@log, ['callback 1', 'handler returned'], 'a clean return, no error';
};

subtest 'on_invalid_json replies and reading continues' => sub {
    my $ws = $client->websocket('/reply');
    $ws->send_text('{bad');
    is $ws->receive_json, { error => 'expected JSON' };
    $ws->send_text('{"n":2}');
    is $ws->receive_json, { got => 2 }, 'the next message is still read';
    $ws->close;
};

subtest 'a sync on_invalid_json works too' => sub {
    my $ws = $client->websocket('/reply-sync');
    $ws->send_text('{bad');
    is $ws->receive_json, { error => 'expected JSON' };
    $ws->send_text('{"n":3}');
    is $ws->receive_json, { got => 3 };
    $ws->close;
};

subtest 'on_invalid_json that dies is an application error (1011)' => sub {
    my $ws = $client->websocket('/raise');
    $ws->send_text('{bad');
    is $ws->close_code, 1011;
    like dies { $ws->close }, qr/bad JSON/, 'the error fails the test client';
};

subtest 'a subclass overrides handle_invalid_json' => sub {
    my $ws = $client->websocket('/subclass');
    $ws->send_text('{bad');
    is $ws->receive_json, { error => 'subclass says: expected JSON' };
    $ws->send_text('{"n":4}');
    is $ws->receive_json, { got => 4 };
    $ws->close;
};

subtest 'a dying message callback is still 1011' => sub {
    my $ws = $client->websocket('/dying-callback');
    $ws->send_text('{"n":5}');
    is $ws->close_code, 1011;
    like dies { $ws->close }, qr/callback broke/;
};

subtest 'manual close mode: nothing reaches the callback after our Close' => sub {
    @log = ();
    my $ws = $client->websocket('/default', close_mode => 'manual');
    $ws->send_text('{bad');
    $ws->send_text('{"n":6}');
    is $ws->close_code, 1007;
    is \@log, ['handler returned'], 'the message after our Close never reached the callback';
    $ws->close;
    $ws->complete_close;
};

done_testing;
