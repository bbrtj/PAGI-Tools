#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use File::Temp qw(tempdir);
use Scalar::Util qw(refaddr);

use lib 'lib';
use PAGI::Compose qw(compose);
use PAGI::Endpoint;
use PAGI::Response::Text ();
use PAGI::Routing qw(endpoint mount route sse websocket);
use PAGI::Test::Client;
use PAGI::Tools ();

# endpoint('Class', %args) loads the class and builds it as the class
# decides. The classes are declared in this file, so most have no .pm file to
# require; the ones that do are written to a temporary directory.

package Local::Greeter {
    use parent 'PAGI::Endpoint::HTTP';
    use Scalar::Util qw(refaddr);
    our $BUILT = 0;

    sub new {
        my ($class, %args) = @_;
        $BUILT++;
        return $class->SUPER::new(%args);
    }

    sub get {
        my ($self, $request) = @_;
        return PAGI::Response::Text->new(
            ($self->{greeting} // 'hello') . ' from ' . refaddr($self));
    }
}

package Local::ArgsRecorder {
    use parent 'PAGI::Endpoint::HTTP';
    our @ARGS;

    sub new {
        my ($class, @args) = @_;
        @ARGS = @args;
        return $class->SUPER::new(@args);
    }
}

# BUILD_APP returning an object: that object answers every request.
package Local::GreeterBuiltOnce {
    use parent -norequire, 'Local::Greeter';
    our $CALLS = 0;

    sub BUILD_APP {
        my ($class, %args) = @_;
        $CALLS++;
        return $class->new(greeting => uc $args{greeting});
    }
}

# BUILD_APP may return any app object, not only an instance of the class.
package Local::Fixed {
    sub BUILD_APP { return PAGI::Response::Text->new('fixed answer') }
}

package Local::Echo {
    use parent 'PAGI::Endpoint::WebSocket';
    use Future::AsyncAwait;

    async sub on_receive {
        my ($self, $websocket, $text) = @_;
        await $websocket->send_text("$self->{prefix}$text");
    }
}

package Local::Ticker {
    use parent 'PAGI::Endpoint::SSE';
    use Future::AsyncAwait;

    async sub on_connect {
        my ($self, $sse) = @_;
        await $sse->send_event(data => $self->{first});
    }
}

package Local::Neither {
    sub BUILD_APP { return 'oops' }
}

package Local::NewReturnsJunk {
    sub new { return {} }
}

package Local::OnlyHelper {
    sub helper { return 1 }
}

package Local::MooHealth {
    use Moo;
    extends 'PAGI::Endpoint::HTTP';
    has version => (is => 'ro', required => 1);
}

package Local::FixedEndpoint {
    our @ISA = ('PAGI::Endpoint');

    sub build { return PAGI::Response::Text->new('built by the subclass') }
}

package main;

# Compiling this call puts a 'helper' symbol in Local::Misspelt's stash, as a
# fully qualified call to a package nobody declared does.
sub never_called { return Local::Misspelt::helper() }

my $lib = tempdir(CLEANUP => 1);
sub write_module {
    my ($path, $source) = @_;
    my @dirs = split m{/}, $path;
    pop @dirs;
    my $dir = $lib;
    for my $part (@dirs) {
        $dir .= "/$part";
        mkdir $dir unless -d $dir;
    }
    open my $fh, '>', "$lib/$path" or die "$path: $!";
    print {$fh} $source;
    close $fh or die "$path: $!";
}
write_module('PAGITestTmp/FileGreeter.pm', <<'PERL');
package PAGITestTmp::FileGreeter;
use parent 'PAGI::Endpoint::HTTP';
sub get { PAGI::Response::Text->new('from a file') }
1;
PERL
write_module('PAGITestTmp/HelperOnly.pm', <<'PERL');
package PAGITestTmp::HelperOnly;
sub helper { 1 }
1;
PERL
write_module('PAGITestTmp/Broken.pm', <<'PERL');
package PAGITestTmp::Broken;
sub new {
1;
PERL
unshift @INC, $lib;

my $this_file = __FILE__;

subtest 'without BUILD_APP the class is built once, with new and the arguments' => sub {
    $Local::Greeter::BUILT = 0;
    my $greeter = endpoint('Local::Greeter', greeting => 'hi');
    is($Local::Greeter::BUILT, 1, 'new runs once, when endpoint() is called');
    isa_ok($greeter, ['Local::Greeter'], 'endpoint() returns the object itself');
    ok(!$greeter->isa('PAGI::Endpoint::PerRequest'), 'not a per-request wrapper');

    my $client = PAGI::Test::Client->new(
        app => compose(routes => [route('/greet' => $greeter)]));
    is([map { $client->get('/greet')->text } 1 .. 2],
        [('hi from ' . refaddr($greeter)) x 2], 'that one object answers every request');
    is($Local::Greeter::BUILT, 1, 'no request builds another');
};

subtest 'the arguments reach new unchanged and in order' => sub {
    my $repo = {};
    endpoint('Local::ArgsRecorder', b => 2, a => 1, repo => $repo);
    is(\@Local::ArgsRecorder::ARGS, [b => 2, a => 1, repo => exact_ref($repo)],
        'the same list, the same references');
};

subtest 'the same class at two routes is two objects' => sub {
    my $app = compose(routes => [
        route('/en' => endpoint('Local::Greeter', greeting => 'hello')),
        route('/fr' => endpoint('Local::Greeter', greeting => 'bonjour')),
    ]);
    my $client = PAGI::Test::Client->new(app => $app);
    my ($en, $fr) = map { $client->get($_)->text } '/en', '/fr';
    like($en, qr/\Ahello from \d+\z/, 'one with its arguments');
    like($fr, qr/\Abonjour from \d+\z/, 'the other with its own');
    isnt(($en =~ /(\d+)\z/)[0], ($fr =~ /(\d+)\z/)[0], 'two objects');
};

subtest 'BUILD_APP returning an app object' => sub {
    $Local::GreeterBuiltOnce::CALLS = 0;
    my $app = compose(routes => [
        route('/once' => endpoint('Local::GreeterBuiltOnce', greeting => 'hi')),
        route('/fixed' => endpoint('Local::Fixed')),
    ]);
    is($Local::GreeterBuiltOnce::CALLS, 1, 'BUILD_APP runs once, when endpoint() is called');
    my $client = PAGI::Test::Client->new(app => $app);
    like($client->get('/once')->text, qr/\AHI from /, 'the object it built answers');
    like($client->get('/once')->text, qr/\AHI from /, 'every request');
    is($Local::GreeterBuiltOnce::CALLS, 1, 'and BUILD_APP is not called again');
    is($client->get('/fixed')->text, 'fixed answer',
        'any app object, not only an instance of the class');
};

subtest 'one spelling at route, websocket, sse and mount' => sub {
    my $app = compose(routes => [
        websocket('/echo' => endpoint('Local::Echo', prefix => 'echo: ')),
        sse('/ticks' => endpoint('Local::Ticker', first => 'tick')),
        mount('/mounted', app => endpoint('Local::Greeter', greeting => 'mounted')),
        route('/file' => endpoint('PAGITestTmp::FileGreeter')),
    ]);
    my $client = PAGI::Test::Client->new(app => $app);
    $client->websocket('/echo', sub {
        my ($ws) = @_;
        $ws->send_text('hi');
        is($ws->receive_text, 'echo: hi', 'websocket');
    });
    $client->sse('/ticks', sub {
        my ($sse) = @_;
        is($sse->receive_event->{data}, 'tick', 'sse');
    });
    like($client->get('/mounted')->text, qr/\Amounted from /, 'mount');
    is($client->get('/file')->text, 'from a file', 'a class with a file is loaded by name');
    ok($INC{'PAGITestTmp/FileGreeter.pm'}, 'which required it');
};

subtest 'mistakes fail at endpoint(), with their own messages' => sub {
    like(dies { endpoint() }, qr/\Aendpoint expects a class name at /, 'no class name');
    like(dies { endpoint('') }, qr/\Aendpoint expects a class name at /, 'an empty one');
    like(dies { endpoint(\'Local::Greeter') }, qr/\Aendpoint expects a class name at /,
        'a reference');
    like(dies { endpoint('Local::Greeter', 'greeting') },
        qr/\Aendpoint arguments must be key\/value pairs at /, 'an odd argument list');
    like(dies { endpoint('Bad Name') }, qr/\Ainvalid endpoint class name 'Bad Name' at /,
        'not a package name');
    like(dies { endpoint('Local::Neither') },
        qr/\ALocal::Neither->BUILD_APP must return an app object \(one with to_app\)/,
        'BUILD_APP returning a string');
    like(dies { endpoint('Local::NewReturnsJunk') },
        qr/\ALocal::NewReturnsJunk->new must return an app object \(one with to_app\)/,
        'new returning a hashref');
    like(dies { endpoint('Local::MooHealth') }, qr/\AMissing required arguments: version/,
        "a singleton missing a required Moo attribute: Moo's own error");
};

subtest 'a class that cannot be loaded' => sub {
    my $line = __LINE__ + 1;
    my $error = dies { PAGI::Endpoint->new('No::Such::Endpoint')->endpoint };
    like($error,
        qr/\Aendpoint class No::Such::Endpoint could not be loaded: Can't locate No\/Such\/Endpoint\.pm in \@INC/,
        'an unknown class');
    my @locations = $error =~ / at (\S+) line (\d+)\./g;
    is(\@locations, [$this_file, $line], 'one location: the line that asked for it');

    like(dies { endpoint('PAGITestTmp::Broken') },
        qr/\Aendpoint class PAGITestTmp::Broken could not be loaded: .*Compilation failed in require/s,
        'a file that does not compile');
};

subtest 'a class with neither new nor BUILD_APP' => sub {
    like(dies { endpoint('PAGITestTmp::HelperOnly') },
        qr/\Aendpoint class PAGITestTmp::HelperOnly has neither new nor BUILD_APP at /,
        'from its file');
    like(dies { endpoint('Local::OnlyHelper') },
        qr/\Aendpoint class Local::OnlyHelper has neither new nor BUILD_APP at /,
        'declared inline: the shape check, not a load error');
    like(dies { endpoint('Local::Misspelt') },
        qr/\Aendpoint class Local::Misspelt has neither new nor BUILD_APP at /,
        'a name some compiled code already used as a package reads as defined');
};

subtest 'the steps are methods a subclass may override' => sub {
    my $endpoint = PAGI::Endpoint->new('Local::Greeter', greeting => 'hi');
    is($endpoint->class, 'Local::Greeter', 'class');
    is([$endpoint->args], [greeting => 'hi'], 'args');

    my $app = Local::FixedEndpoint->new('Local::Greeter')->endpoint;
    isa_ok($app, ['PAGI::Response::Text'], 'an overridden build goes through app_from');
    is(PAGI::Test::Client->new(app => $app)->get('/')->text, 'built by the subclass',
        'and answers');
};

subtest 'endpoint is exported by PAGI::Routing and PAGI::Tools' => sub {
    ok(\&PAGI::Tools::endpoint == \&PAGI::Routing::endpoint, 'one sub');
    ok((grep { $_ eq 'endpoint' } @{ $PAGI::Routing::EXPORT_TAGS{all} }),
        "in PAGI::Routing's :all");
    ok(!(grep { $_ eq 'endpoint' } @{ $PAGI::Routing::EXPORT_TAGS{routes} }),
        "not in PAGI::Routing's :routes");
    ok(!(grep { $_ eq 'endpoint' } @{ $PAGI::Tools::EXPORT_TAGS{routes} }),
        "not in PAGI::Tools' :routes");
};

done_testing;
