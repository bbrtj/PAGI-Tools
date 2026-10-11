use strict;
use warnings;
use Future::AsyncAwait;
use PAGI::Compose qw(compose);
use PAGI::Pages qw(not_found);
use PAGI::Routing qw(:routes :middleware);
use PAGI::Utils::Middleware qw(wrap_response_headers);
use MyApp::Routes::Home ();

sub api_not_found {
    my ($request) = @_;
    return not_found(detail => 'No API route matched');
}

sub root_not_found {
    my ($request) = @_;
    return not_found(detail => 'No root route matched');
}

# A route middleware that adds one response header. wrap_response_headers
# hands the editor a PAGI::Headers copy of each response's headers and sends
# a new start event, so the handler's own header list is never changed.
my $home_header = sub {
    my ($app) = @_;

    return async sub {
        my ($scope, $receive, $send) = @_;
        my $wrapped_send = wrap_response_headers($send, sub {
            my ($headers) = @_;
            $headers->set('x-route-demo', 'home');
        });

        await $app->($scope, $receive, $wrapped_send);
    };
};

my $api_routing = router(
    routes => [
        route('/items/{id}' => \&MyApp::Routes::Home::show_item,
            name        => 'item',
            desc        => 'Show one numeric item',
            methods     => ['GET'],
            constraints => { id => qr/\d+/ },
        ),
    ],
    desc => 'Example JSON API',
    http_default => \&api_not_found,
);

compose(
    routes => [
        route('/' => \&MyApp::Routes::Home::home,
            name       => 'home',
            desc       => 'HTML home page',
            middleware => [middleware($home_header)],
        ),
        mount('/api',
            app  => $api_routing,
            name => 'api',
            desc => 'Example JSON API',
        ),
    ],
    http_default => \&root_not_found,
    desc => 'Declarative routing example',
);
