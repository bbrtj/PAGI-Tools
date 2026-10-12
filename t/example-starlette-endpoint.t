use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../lib";

BEGIN { plan skip_all => 'examples/starlette-endpoint requires Perl 5.40' if $] < 5.040 }

use PAGI::Test::Client;

# The Starlette HTTPEndpoint port: the five requests its README shows.

my $app = do "$Bin/../examples/starlette-endpoint/app.pl" or die $@ || $!;
my $client = PAGI::Test::Client->new(app => $app);

my $res = $client->get('/httpp');
is [$res->status, $res->json], [200, { message => 'This handled a GET request!' }], 'GET';

$res = $client->post('/httpp');
is [$res->status, $res->json], [200, { message => 'This handled a POST request!' }], 'POST';

$res = $client->put('/httpp');
is [$res->status, $res->text, $res->header('Allow')],
    [405, 'Method Not Allowed', 'GET, HEAD, OPTIONS, POST'], 'PUT is a 405 with Allow';

$res = $client->head('/httpp');
is [$res->status, $res->content], [200, ''], 'HEAD is answered by get, without a body';

$res = $client->options('/httpp');
is [$res->status, $res->header('Allow')], [204, 'GET, HEAD, OPTIONS, POST'], 'OPTIONS is a 204 with Allow';

done_testing;
