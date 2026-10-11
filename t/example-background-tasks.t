use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use PAGI::Test::Client;

# Background work from ordinary handlers: each route starts its
# fire-and-forget work and returns a Response. No native applications.

my $file = "$Bin/../examples/background-tasks/app.pl";
my $source = do { open my $fh, '<', $file or die "$file: $!"; local $/; <$fh> };

unlike($source, qr/\bas_app_object\b/, 'no route needs as_app_object');
unlike($source, qr/\(\$scope,\s*\$receive,\s*\$send\)|invoke_app|PAGI::WebSocket->new/,
    'no raw PAGI application');
like($source, qr/route\('\/async'\s*=>\s*\\&async_tasks\)/, '/async is a Request handler');
like($source, qr/route\('\/signup'\s*=>\s*\\&signup,\s*methods\s*=>\s*\['POST'\]\)/,
    '/signup is a POST Request handler');
like($source, qr/websocket\('\/ws'\s*=>\s*\\&messages\)/, '/ws is a one-$ws handler');

my $app = do $file;
is($@, '', 'the example loads');
isa_ok($app, 'PAGI::Compose');

like($source, qr/\$state->\{background\} = PAGI::FutureOwner->new/,
    'the owner is built at lifespan startup');
unlike($source, qr/^my \$background/m, 'not as a file-scoped global');

my ($stderr, %res) = ('');
{
    local *STDERR;
    open STDERR, '>', \$stderr or die $!;
    # The owner lives in lifespan state, so the client runs the lifespan;
    # stop waits for the work the handlers started.
    my $client = PAGI::Test::Client->new(app => $app, lifespan => 1);
    $client->start;
    $res{index}  = $client->get('/');
    $res{async}  = $client->get('/async');
    $res{signup} = $client->post('/signup', json => { email => 'ada@example.com' });
    $client->websocket('/ws', sub {
        my ($ws) = @_;
        is($ws->receive_text, 'Connected! Send a message.', 'the WebSocket greets');
        $ws->send_text('hello');
        is($ws->receive_text, 'Got: hello', 'and answers each message');
    });
    $client->stop;
}

like($stderr, qr/\[async\] Analytics logged!/, 'shutdown waited for the analytics the handlers started');
like($stderr, qr/\[async\] Email sent to ada\@example\.com!/, 'and for the email started after the response');

is($res{index}->status, 200, 'the index is served');
like($res{index}->text, qr/Background Tasks Demo/, 'with its demonstration page');

is($res{async}->status, 200, '/async responds at once');
is($res{async}->json->{status}, 'ok', 'with its JSON body');

is($res{signup}->status, 201, '/signup creates');
like($res{signup}->json->{message}, qr/ada\@example\.com/, 'naming the address');

like($stderr, qr/\[async\] Sending welcome email to ada\@example\.com/,
    'the signup started its background email');
like($stderr, qr/\[async\] Logging 'ws_message' to analytics/,
    'and WebSocket messages start background work too');

done_testing;
