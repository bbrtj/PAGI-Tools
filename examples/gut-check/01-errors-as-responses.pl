#!/usr/bin/env perl
#
# Starlette's HTTPException, the PAGI-Tools way.
#
# Starlette:
#
#     async def show(request):
#         note = NOTES.get(request.path_params["id"])
#         if note is None:
#             raise HTTPException(status_code=404, detail="no such note")
#         return JSONResponse(note)
#
#     async def http_exception(request, exc):
#         return JSONResponse({"error": exc.detail}, status_code=exc.status_code)
#
#     app = Starlette(routes=[...], exception_handlers={HTTPException: http_exception})
#
# PAGI-Tools: throw a PAGI::Exception::HTTP (what went wrong), and let one
# ErrorHandler handler decide how errors look. Without the handler, the stock
# page answers with the right status and the message. A thrown response
# (die response('JSON', ..., status => 404)) also works with no handler at
# all: it answers itself.
#
# A path no route matches is not an error: the router answers it, and the
# handler never sees it. http_default sets that answer (a 405 is the router's
# too; change it with a middleware). Starlette sends both through its handler.
#
# Run:  pagi-server --app examples/gut-check/01-errors-as-responses.pl --port 5000
# Try:  curl -i localhost:5000/notes/1
#       curl -i localhost:5000/notes/9      # 404, thrown from deep in the model
#       curl -i localhost:5000/boom         # an ordinary bug: the stock 500
#       curl -i localhost:5000/nope         # no route: the router's 404, same JSON shape

use v5.40;
use Future::AsyncAwait;
use PAGI::Exception::HTTP;
use PAGI::Tools qw(compose error_context middleware response route);

my %NOTES = (1 => { id => 1, text => 'buy milk' });

# Deep in the "model": say what went wrong, not how it looks.
sub find_note ($id) {
    return $NOTES{$id} // PAGI::Exception::HTTP->throw(404, "no such note: $id");
}

async sub show ($request) {
    return response('JSON', find_note($request->path_param('id')));
}

async sub boom ($request) {
    die "an ordinary bug\n";
}

# The exception handler: errors the app expects become JSON; bugs keep the
# stock 500. A response with no status of its own takes the error's.
sub json_errors ($request) {
    my $error = error_context($request);
    return $error->default if $error->is_server_error;
    return response('JSON', { error => $error->message });
}

compose(
    routes => [
        route('/notes/{id}' => \&show),
        route('/boom' => \&boom),
    ],
    http_default => sub ($request) { response('JSON', { error => 'Not Found' }, status => 404) },
    middleware => [middleware('ErrorHandler', handler => \&json_errors)],
);
