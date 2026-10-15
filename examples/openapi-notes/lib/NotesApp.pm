package NotesApp;

# A notes API whose OpenAPI document is generated from its routes. The root
# is one PAGI::App::Compose; its part, NotesApp::Notes, is a Router, so the
# document describes every route in it. /static is a separate application
# (a mount routing does not see into), so the document leaves it out.
#
# The document is served by wrapping the application from outside: the
# wrapper holds the whole application, answers GET /openapi.json, and hands
# everything else to it.
#
# Run:  pagi-server -I lib --app lib/NotesApp.pm --port 5000
# Try:  curl -s localhost:5000/openapi.json | python3 -m json.tool
#       curl -s localhost:5000/notes/
#       curl -s -X POST localhost:5000/notes/ -H 'Authorization: Bearer writer' \
#            -H 'Content-Type: application/json' -d '{"text":"buy milk"}'

use v5.40;
use parent 'PAGI::App::Compose';
use File::Basename qw(dirname);
use PAGI::App::File;
use PAGI::Auth qw(auth_result unauth_result);
use PAGI::Auth::SimpleUser;
use PAGI::Tools qw(mount middleware openapi);
use NotesApp::Notes;

# Demo bearer tokens and the scopes they grant; a real application verifies
# its tokens.
my %GRANTS = (reader => ['notes:read'], writer => ['notes:read', 'notes:write']);

sub bearer ($request) {
    my $token = $request->bearer_token;
    return unauth_result() unless defined $token && $GRANTS{$token};
    return auth_result(
        user   => PAGI::Auth::SimpleUser->new(identity => $token),
        scopes => $GRANTS{$token},
    );
}

sub routes ($self) {
    return [
        mount('/notes', name => 'notes', app => NotesApp::Notes->routing),
        mount('/static', app => PAGI::App::File->new(root => dirname(__FILE__) . '/../public')),
    ];
}

sub app_middleware ($self) {
    return [ middleware('Authentication', backend => \&bearer) ];
}

sub to_app ($self) {
    return openapi($self->composition,
        title           => 'Notes',
        version         => '1.0.0',
        security_scheme => [bearer => { type => 'http', scheme => 'bearer' }],
        components      => { schemas => NotesApp::Notes->schemas },
    );
}

__PACKAGE__->run_if_script;
