package MyApp;
use strict;
use warnings;
use parent 'PAGI::App';

use MyApp::Main;
use MyApp::API;
use PAGI::Compose qw(compose);

# The whole application, in lib/. Serve it with
#   pagi-server -I examples/endpoint-class-demo/lib \
#       --app examples/endpoint-class-demo/lib/MyApp.pm
# or try one request without a server:
#   perl -I examples/endpoint-class-demo/lib \
#       examples/endpoint-class-demo/lib/MyApp.pm GET /

sub to_app {
    my ($self) = @_;
    my @users = (
        { id => 1, name => 'Alice' },
        { id => 2, name => 'Bob' },
    );
    my $api  = MyApp::API->new(users => \@users);
    my $main = MyApp::Main->new(api => $api);

    return compose(
        routes   => $main->routes,
        lifespan => {
            startup => sub {
                my ($state) = @_;
                $state->{resource} = { name => 'demo-resource', open => 1 };
                $state->{metrics} = { requests => 0, websocket_messages => 0 };
            },
            shutdown => sub {
                my ($state) = @_;
                $state->{resource}{open} = 0;
                $state->{resource}{closed} = 1;
            },
        },
    )->to_app;
}

__PACKAGE__->run_if_script;
