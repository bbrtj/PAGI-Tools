package MyApp::Middleware::AccessLog;
use v5.40;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;
use PAGI::Request;

# Records who asked for what. It asks for the viewer through a Request, so the
# viewer's builder gets one; the handler then gets the same viewer, looked up
# once.
sub wrap ($self, $app) {
    return async sub ($scope, $receive, $send) {
        if ($scope->{type} eq 'http') {
            my $state  = PAGI::Request->new($scope, $receive)->state;
            my $viewer = await $state->get('viewer');
            push $state->get('access_log')->@*,
                join ' ', $scope->{method}, $scope->{path}, $viewer ? $viewer->{name} : 'anonymous';
        }
        await $app->($scope, $receive, $send);
    };
}

1;
