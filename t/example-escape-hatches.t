use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../lib";

BEGIN { plan skip_all => 'examples/escape-hatches requires Perl 5.40' if $] < 5.040 }

use PAGI::Test::Client;

# The same app, one rung at a time from the easy way down to the raw protocol.

my $app = do "$Bin/../examples/escape-hatches/app.pl" or die $@ || $!;
my $client = PAGI::Test::Client->new(app => $app);

my $res = $client->get('/easy?who=ada');
is [$res->status, $res->text], [200, 'hello, ada'], '1. the easy way: a handler returns a response value';

$res = $client->get('/under');
is [$res->status, $res->json->{connected}, $res->json->{scope_type}], [200, 1, 'http'],
    '2. a handler reads the raw scope and the connection object';

$res = $client->get('/raw?who=ada');
is [$res->status, $res->header('Content-Type'), $res->text], [200, 'text/plain', "raw, ada\nsent in two events\n"],
    '3. a handler returns a hand-written application mid-request';

$res = $client->get('/legacy/anything');
is [$res->status, $res->text], [200, 'a raw app at /legacy, asked for /anything'],
    '4. a raw application mounted at a route';

$res = $client->get('/stamped');
is [$res->status, $res->header('X-Stamped'), $res->text], [200, 'by raw middleware', 'stamped'],
    '5. raw middleware edits the protocol events on the way out';

done_testing;
