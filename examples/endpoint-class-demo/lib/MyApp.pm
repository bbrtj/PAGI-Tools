package MyApp;
use strict;
use warnings;
use parent 'PAGI::App::Compose';

use MyApp::Main;
use MyApp::API;

# The whole application, in lib/. Serve it with
#   pagi-server -I examples/endpoint-class-demo/lib \
#       --app examples/endpoint-class-demo/lib/MyApp.pm
# or try one request without a server:
#   perl -I examples/endpoint-class-demo/lib \
#       examples/endpoint-class-demo/lib/MyApp.pm GET /

sub routes {
    my ($self) = @_;
    my @users = (
        { id => 1, name => 'Alice' },
        { id => 2, name => 'Bob' },
    );
    my $api = MyApp::API->new(users => \@users);
    return MyApp::Main->new(api => $api)->routes;
}

sub on_startup {
    my ($self, $state) = @_;
    $state->{resource} = { name => 'demo-resource', open => 1 };
    $state->{metrics}  = { requests => 0, websocket_messages => 0 };
}

sub on_shutdown {
    my ($self, $state) = @_;
    $state->{resource}{open}   = 0;
    $state->{resource}{closed} = 1;
}

__PACKAGE__->run_if_script;
