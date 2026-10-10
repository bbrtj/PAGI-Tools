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
# PAGI-Tools has no HTTPException class, and none is needed: a response is a
# value, so a handler can throw the response itself. One ErrorHandler handler
# turns "an error that is a response" into the answer; everything else gets
# the stock error page.
#
# Run:  pagi-server --app examples/gut-check/01-errors-as-responses.pl --port 5000
# Try:  curl -i localhost:5000/notes/1
#       curl -i localhost:5000/notes/9      # 404, thrown from deep in the model
#       curl -i localhost:5000/boom         # an ordinary bug: the stock 500

use v5.40;
use Future::AsyncAwait;

use PAGI::Compose qw(compose);
use PAGI::ErrorContext qw(error_context);
use PAGI::Response qw(response);
use PAGI::Routing qw(route middleware);

my %NOTES = (1 => { id => 1, text => 'buy milk' });

# Deep in the "model": throw the answer, not a code.
sub find_note ($id)
{
    return $NOTES{$id} // die response('JSON',
        { error => "no such note: $id" },
        status => 404,
    );
}

async sub show ($request)
{
    return response('JSON', find_note($request->path_param('id')));
}

async sub boom ($request)
{
    die "an ordinary bug\n";
}

# The whole "exception handler" table: a thrown response answers itself.
sub answer_thrown_responses ($request)
{
    my $error = error_context($request);
    my $thrown = $error->exception;
    return $thrown if builtin::blessed($thrown) && $thrown->can('to_app');
    return $error->default;
}

compose(
    routes => [
        route('/notes/{id}' => \&show),
        route('/boom' => \&boom),
    ],
    middleware => [middleware('ErrorHandler', handler => \&answer_thrown_responses)],
);
