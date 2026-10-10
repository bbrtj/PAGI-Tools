package PAGITest::LeavingClient;

# A client that leaves just as the handshake goes out: wraps an application
# so that, once its websocket.accept or sse.start has been sent, the test
# connection ends and delivers its terminal notifications, as a server does
# when the peer is already gone. Code the handler runs after the handshake
# then meets a connection that has ended.

use strict;
use warnings;
use Exporter 'import';
use Future::AsyncAwait;
use PAGI::Utils::Middleware qw(wrap_send);

our @EXPORT_OK = qw(leaves_at_handshake);

my %HANDSHAKE = map { $_ => 1 } qw(websocket.accept sse.start);

sub leaves_at_handshake {
    my ($app) = @_;
    $app = $app->to_app if ref $app ne 'CODE';
    return async sub {
        my ($scope, $receive, $send) = @_;
        my $connection = $scope->{'pagi.connection'};
        return await $app->($scope, $receive, wrap_send($send, async sub {
            my ($event, $next) = @_;
            await $next->($event);
            if ($HANDSHAKE{$event->{type}}) {
                $connection->_mark_disconnected('client_closed');
                $connection->_deliver_notifications;
            }
        }));
    };
}

1;
