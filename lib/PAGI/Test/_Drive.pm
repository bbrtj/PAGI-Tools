package PAGI::Test::_Drive;

use strict;
use warnings;
use Future;

# Internal to PAGI's in-process test client. Not public API.

# How long the test client waits for an application that is waiting on real
# I/O before giving up, in seconds.
our $TIMEOUT = 5;

# Returns 1 once $future is ready, driving Future::IO's event loop for at most
# $seconds, else 0. ->get on a plain pending Future cannot block, so the wait
# is joined with a Future::IO sleep: wait_any builds its result from the first
# subfuture that is not a plain Future -- the sleep -- whose ->get runs the
# loop. Without Future::IO nothing can be waiting on real I/O, so a pending
# $future cannot progress and this returns 0 at once. A failed $future is the
# caller's to read.
sub drive {
    my ($future, $seconds) = @_;
    return 1 if $future->is_ready;
    return 0 unless eval { require Future::IO; 1 };

    my $waiter = Future->wait_any(
        $future->without_cancel,
        Future::IO->sleep($seconds),
    );
    eval { $waiter->get };
    return $future->is_ready ? 1 : 0;
}

1;
