#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';
use lib 't/lib';
use PAGI::WebSocket;
use PAGITest::Connected qw(ws_scope);

# Helper to create connected WebSocket
sub create_ws {
    my (%opts) = @_;
    my @sent;
    my $should_fail = $opts{fail};

    my $send = sub {
        my $event = $_[0];
        push @sent, $event;
        # Only fail on websocket.send, not on accept
        if ($should_fail && $event->{type} eq 'websocket.send') {
            return Future->fail('Connection lost');
        }
        return Future->done;
    };

    my $scope = ws_scope();
    my $receive = sub { Future->done({ type => 'websocket.connect' }) };

    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    return ($ws, \@sent);
}

subtest 'try_send_text returns true on success' => sub {
    my ($ws, $sent) = create_ws();
    @$sent = ();

    my $result = $ws->try_send_text('Hello')->get;

    ok($result, 'returns true on success');
    is($sent->[0]{text}, 'Hello', 'message sent');
};

subtest 'try_send_text returns false on failure' => sub {
    my ($ws, $sent) = create_ws(fail => 1);
    @$sent = ();

    my $result = $ws->try_send_text('Hello')->get;

    ok(!$result, 'returns false on failure');
    # A failed send is not a disconnect: connection state is left untouched.
    ok(!$ws->is_closed, 'does not mark the connection closed');
    is($ws->close_code, undef, 'no fabricated 1006 close code');
};

subtest 'try_send_text returns false when already closed' => sub {
    my ($ws, $sent) = create_ws();
    $ws->close->get;
    @$sent = ();

    my $result = $ws->try_send_text('Hello')->get;

    ok(!$result, 'returns false when closed');
    is(scalar @$sent, 0, 'no message sent');
};

subtest 'try_send_bytes works like try_send_text' => sub {
    my ($ws, $sent) = create_ws();
    @$sent = ();

    my $result = $ws->try_send_bytes("\x00\x01")->get;

    ok($result, 'returns true on success');
    is($sent->[0]{bytes}, "\x00\x01", 'bytes sent');
};

subtest 'try_send_bytes returns false on failure' => sub {
    my ($ws, $sent) = create_ws(fail => 1);
    @$sent = ();

    my $result = $ws->try_send_bytes("\x00")->get;

    ok(!$result, 'returns false on failure');
    ok(!$ws->is_closed, 'does not mark the connection closed');
};

subtest 'try_send_bytes returns false when already closed' => sub {
    my ($ws, $sent) = create_ws();
    $ws->close->get;
    @$sent = ();

    my $result = $ws->try_send_bytes("\x00")->get;

    ok(!$result, 'returns false when closed');
    is(scalar @$sent, 0, 'no message sent');
};

subtest 'try_send_json works like try_send_text' => sub {
    my ($ws, $sent) = create_ws();
    @$sent = ();

    my $result = $ws->try_send_json({ msg => 'hi' })->get;

    ok($result, 'returns true on success');
    like($sent->[0]{text}, qr/"msg"/, 'JSON sent');
};

subtest 'try_send_json returns false on failure' => sub {
    my ($ws, $sent) = create_ws(fail => 1);
    @$sent = ();

    my $result = $ws->try_send_json({ msg => 'hi' })->get;

    ok(!$result, 'returns false on failure');
    ok(!$ws->is_closed, 'does not mark the connection closed');
};

subtest 'try_send_json returns false when already closed' => sub {
    my ($ws, $sent) = create_ws();
    $ws->close->get;
    @$sent = ();

    my $result = $ws->try_send_json({ msg => 'hi' })->get;

    ok(!$result, 'returns false when closed');
    is(scalar @$sent, 0, 'no message sent');
};

subtest 'try_send_text before accept returns false and sends nothing' => sub {
    my @sent;
    my $ws = PAGI::WebSocket->new(ws_scope(), sub { Future->done({ type => 'websocket.connect' }) },
        sub { push @sent, $_[0]; Future->done });

    is($ws->connection_state, 'connecting', 'not yet accepted');
    is($ws->try_send_text('early')->get, 0, 'returns false');
    is(scalar @sent, 0, 'no message sent');
};

subtest 'try_send_text while closing returns false and sends nothing' => sub {
    my ($ws, $sent) = create_ws();
    $ws->close->get;
    @$sent = ();

    is($ws->connection_state, 'closing', 'our Close is sent, the peer has not answered');
    is($ws->try_send_text('late')->get, 0, 'returns false');
    is(scalar @$sent, 0, 'no message sent');
};

done_testing;
