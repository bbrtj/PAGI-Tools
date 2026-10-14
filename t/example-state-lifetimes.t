use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);

BEGIN { plan skip_all => 'examples/state-lifetimes requires Perl 5.40' if $] < 5.040 }

use lib "$Bin/../lib", "$Bin/../examples/state-lifetimes/lib";
use PAGI::Test::Client;

my $provider = do "$Bin/../examples/state-lifetimes/lib/MyApp.pm" or die $@ || $!;
my $db;
PAGI::Test::Client->run($provider, sub {
    my ($client) = @_;
    my $state = $client->state;
    ok !$state->{db}->built, 'db is not built at startup';

    is $client->get('/')->text, 'Members: Ada', 'anonymous';
    ok $state->{db}->built, 'the first request built db';
    $db = $state->{db}->value->get;

    my $before = $MyApp::Members::LOOKUPS;
    is $client->get('/', headers => { Cookie => 'token=ada-token' })->text,
        'Hello Ada. Members: Ada', 'the viewer, from the cookie';
    is $MyApp::Members::LOOKUPS - $before, 1,
        'one lookup although the middleware and the handler both asked';
    is $state->{access_log}, ['GET / anonymous', 'GET / Ada'], 'the access log';

    my $bad = $client->post('/join', form => [[name => ''], [email => 'nope']]);
    is [$bad->status, $bad->json],
        [422, { errors => { name => 'is required', email => 'is not an email address' } }],
        'an invalid submission';
    my $ok = $client->post('/join', form => [[name => 'Grace'], [email => 'grace@example.com']]);
    is [$ok->status, $ok->header('Location')], [303, '/'], 'a valid one';
    my $again = $client->post('/join', form => [[name => 'Grace'], [email => 'grace@example.com']]);
    is $again->json, { errors => { email => 'is already a member' } },
        "a fresh form: only this submission's error";
    is $client->get('/')->text, 'Members: Ada, Grace', 'the new member';
    ok $db->is_open, 'the connection is open while serving';
});
ok !$db->is_open, 'shutdown closed the connection';

done_testing;
