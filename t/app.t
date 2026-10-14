use strict;
use warnings;
use Test2::V0;
use File::Temp qw(tempdir);
use Future;
use Future::AsyncAwait;
use lib 'lib';
use PAGI::App;
use PAGI::Test::Client;
use PAGI::Tools qw(compose response route);

package Local::Native {
    use parent -norequire, 'PAGI::App';
    use Future::AsyncAwait;
    our $PREPARED = 0;
    sub prepare_app { $PREPARED++ }
    async sub call {
        my ($self, $scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [['content-type', 'text/plain']] });
        await $send->({ type => 'http.response.body', body => "hello $self->{name}", more => 0 });
    }
}
package Local::Composed {
    use parent -norequire, 'PAGI::App';
    use PAGI::Tools qw(compose response route);
    sub to_app { compose(routes => [route('/' => sub { response('Text', 'composed') })])->to_app }
}
package Local::Empty { use parent -norequire, 'PAGI::App' }
package main;

subtest 'new takes a list or a hashref' => sub {
    is { %{ Local::Native->new(name => 'a') } }, { name => 'a' }, 'a list';
    is { %{ Local::Native->new({ name => 'b' }) } }, { name => 'b' }, 'a hashref';
};

subtest 'to_app runs prepare_app and returns a coderef calling call' => sub {
    $Local::Native::PREPARED = 0;
    my $app = Local::Native->new(name => 'x');
    my $code = $app->to_app;
    is ref($code), 'CODE', 'a coderef';
    is $Local::Native::PREPARED, 1, 'prepare_app ran once';
    is(PAGI::Test::Client->new(app => $code)->get('/')->text, 'hello x', 'it calls call');
    $app->to_app;
    is $Local::Native::PREPARED, 2, 'and again for each to_app';
};

subtest 'overriding to_app replaces the whole application' => sub {
    is(PAGI::Test::Client->new(app => Local::Composed->new)->get('/')->text, 'composed');
};

subtest 'neither call nor to_app' => sub {
    my $code = Local::Empty->new->to_app;
    like dies { $code->({ type => 'http' }, sub {}, sub {}) },
        qr/\ALocal::Empty must implement call or override to_app/, 'calling it dies';
};

SKIP: {
    skip 'Moo is not installed', 1 unless eval { require Moo; 1 };
    subtest 'a Moo subclass' => sub {
        eval q{
            package Local::MooApp;
            use Moo;
            extends 'PAGI::App';
            has name => (is => 'ro', default => 'moo');
            sub call { my ($self, $s, $r, $send) = @_;
                $send->({ type => 'http.response.start', status => 200, headers => [] })->then(sub {
                    $send->({ type => 'http.response.body', body => $self->name, more => 0 }) }) }
            1;
        } or die $@;
        is Local::MooApp->new->name, 'moo', 'default';
        is Local::MooApp->new({ name => 'h' })->name, 'h', 'a hashref';
        is(PAGI::Test::Client->new(app => Local::MooApp->new(name => 'l'))->get('/')->text, 'l', 'answers');
    };
}

SKIP: {
    skip 'Moose is not installed', 1 unless eval { require Moose; 1 };
    subtest 'a Moose subclass without MooseX::NonMoose is refused at new' => sub {
        eval q{ package Local::MooseApp; use Moose; extends 'PAGI::App'; 1 } or die $@;
        like dies { Local::MooseApp->new },
            qr/\APAGI::App subclass Local::MooseApp is a Moose class whose new is not Moose's/, 'loud';
    };
}

# A module file whose new counts constructions, loaded the ways a server
# and a test load it.
my $dir = tempdir(CLEANUP => 1);
mkdir "$dir/Local";
open my $fh, '>', "$dir/Local/Modulino.pm" or die $!;
print {$fh} <<'PERL';
package Local::Modulino;
use strict;
use warnings;
use parent 'PAGI::App';
our $BUILT = 0;
sub new { $BUILT++; shift->SUPER::new(@_) }
sub to_app { require PAGI::Tools; PAGI::Tools::compose(routes => [PAGI::Tools::route('/' => sub { PAGI::Tools::response('Text', 'modulino') })])->to_app }
__PACKAGE__->run_if_script;
PERL
close $fh;

subtest 'loaded by path, as pagi-server --app does: builds nothing until to_app' => sub {
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    my $provider = do "$dir/Local/Modulino.pm";
    die $@ if $@;
    ok $provider->can('to_app') && !$provider->isa('Local::Modulino'), 'a provider, not the class';
    is $Local::Modulino::BUILT, 0, 'loading built nothing';
    is $INC{'Local/Modulino.pm'}, "$dir/Local/Modulino.pm", 'recorded under its module name';
    my $code = $provider->to_app;
    is $Local::Modulino::BUILT, 1, 'to_app built it once';
    is(PAGI::Test::Client->new(app => $code)->get('/')->text, 'modulino', 'and it answers');
    unshift @INC, $dir;
    require Local::Modulino;
    shift @INC;
    is \@warnings, [], 'a later require compiled nothing again';
};

done_testing;
