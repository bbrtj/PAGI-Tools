package PAGI::App;

use strict;
use warnings;
use Carp qw(croak);
use PAGI::Utils ();

# Arguments as a list or one hashref, as Plack::Component and Moo accept.
sub new {
    my $class = shift;
    my %args = @_ == 1 && ref($_[0]) eq 'HASH' ? %{$_[0]} : @_;
    # A Moose subclass without MooseX::NonMoose arrives here instead of its
    # own new, and its required/default/BUILD would be silently ignored.
    my $error = PAGI::Utils::_moose_constructor_error($class, "PAGI::App subclass $class");
    croak $error if defined $error;
    return bless \%args, $class;
}

# Runs each time to_app builds the application.
sub prepare_app { return }

sub to_app {
    my ($self) = @_;
    $self->prepare_app;
    return sub { $self->call(@_) };
}

# The application: ($scope, $receive, $send), returning a Future. A classic
# application writes call; one that replaces the whole application overrides
# to_app.
sub call {
    my ($self) = @_;
    croak ref($self) . ' must implement call or override to_app';
}

# The module's last line, in place of 1;
#   loaded (pagi-server --app, require, use): an application provider that
#     builds nothing until a server calls its to_app;
#   run as a script: run(@ARGV), whose result is the exit status.
sub run_if_script {
    my $proto = shift;
    if (caller(1)) {
        # Loaded by path (pagi-server --app does "do /abs/lib/MyApp.pm"):
        # record it under its module name too, so a later "use MyApp" finds
        # it instead of compiling the file again.
        (my $key = (ref($proto) || $proto) . '.pm') =~ s{::}{/}g;
        $INC{$key} //= (caller(0))[1];
        return PAGI::App::_Deferred->new($proto);
    }
    my $self = ref($proto) ? $proto : $proto->new;
    exit $self->run(@ARGV);
}

package PAGI::App::_Deferred;

# Holds the class (or object) until a server asks for the application, so
# loading the module constructs nothing. Internal.
sub new    { my ($class, $proto) = @_; return bless { proto => $proto }, $class }
sub to_app { my $proto = $_[0]{proto}; return (ref($proto) ? $proto : $proto->new)->to_app }

1;

__END__

=head1 NAME

PAGI::App - A base class for PAGI applications, runnable from their own module

=head1 SYNOPSIS

An application that replaces the whole application with C<to_app>, here a
Compose application, in F<lib/MyApp.pm>:

    package MyApp;
    use strict;
    use warnings;
    use parent 'PAGI::App';
    use PAGI::Tools qw(compose response route);

    sub to_app {
        my ($self) = @_;
        return compose(routes => [
            route('/' => sub { response('Text', 'hello') }),
        ])->to_app;
    }

    __PACKAGE__->run_if_script;

Serve it, or try one request from the shell without a server:

    pagi-server -Ilib --app lib/MyApp.pm
    perl -Ilib lib/MyApp.pm GET /

A classic application writes C<call>, the PAGI application itself:

    package MyApp::Ping;
    use strict;
    use warnings;
    use parent 'PAGI::App';
    use Future::AsyncAwait;

    async sub call {
        my ($self, $scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200,
                        headers => [['content-type', 'text/plain']] });
        await $send->({ type => 'http.response.body', body => 'pong' });
    }

    __PACKAGE__->run_if_script;

=head1 DESCRIPTION

An optional base class for an application: anything with C<to_app> is an
application, with or without it. It has the shape of L<Plack::Component>
(C<new>, C<prepare_app>, C<to_app>, C<call>), and the modulino of
L<Web::Simple::Application>: ending the module with
C<< __PACKAGE__->run_if_script >> in place of C<1;> makes the same file an
application a server loads and a program you can run.

A subclass does one of two things:

=over 4

=item * writes C<call>, the application, called with
C<($scope, $receive, $send)> and returning a L<Future>; or

=item * overrides C<to_app> to return the whole application, as a Compose
application does.

=back

=head1 METHODS

=head2 new

    my $app = MyApp->new(%args);
    my $app = MyApp->new(\%args);

Blesses a hash of the arguments, given as a list or as one hashref. There is
no initialisation hook: a L<Moo> subclass validates with its attributes and
C<BUILD>, and a plain class overrides C<new>.

=head2 prepare_app

Called by C<to_app> each time it builds the application, before it returns.
Does nothing by default; a subclass that writes C<call> may set up here what
C<call> uses.

=head2 to_app

    my $code = $app->to_app;

Runs C<prepare_app> and returns the PAGI application: a code reference that
calls C<< $app->call($scope, $receive, $send) >>. Override it to return a
whole application of your own instead.

=head2 call

    async sub call { my ($self, $scope, $receive, $send) = @_; ... }

The application. The default dies "Class must implement call or override
to_app".

=head2 run_if_script

    __PACKAGE__->run_if_script;

The module's last line, in place of C<1;>. When the module is loaded (by a
server's C<--app>, by C<require> or by C<use>), it returns an application
provider: an object whose C<to_app> builds the application, with C<new> and
then C<to_app>, only when a server calls it. Loading the module therefore
constructs nothing. It also records the module in C<%INC> under its module
name, so a C<use MyApp> after a server loaded the file by its path does not
compile it again.

When Perl runs the file as the program, it builds the application with
C<new> and exits with what C<run> returns.

=head1 SERVING

    pagi-server -Ilib --app lib/MyApp.pm

A server builds the application with C<new> and no arguments, so the
application bootstraps its own configuration: attribute defaults, the
environment, or files it reads. A L<Moo> C<required> attribute without a
default cannot be served this way.

The application is recorded in C<%INC> when its last line runs, so code that
C<use>s the application class from the application module's own
compile-time C<use> lines would still load the file twice: do not do that.

=head1 MOO AND MOOSE

A L<Moo> class C<< extends 'PAGI::App' >> and keeps its attributes,
C<required>, C<default>, C<isa> and C<BUILD>; C<new> accepts the hashref
form Moo passes on. A L<Moose> class needs C<use MooseX::NonMoose> after
C<use Moose>; without it C<new> dies saying so, since the class's
attributes would otherwise be ignored.

=head1 SEE ALSO

L<Plack::Component>, L<Web::Simple::Application>, L<PAGI::Compose>,
L<PAGI::Test::Client>

=cut
