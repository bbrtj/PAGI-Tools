#!/usr/bin/env perl
#
# One URL, two representations: HTML for browsers, JSON for API clients,
# chosen from the Accept header (quality values included); 406 otherwise.
#
# Starlette has no negotiation helper; the usual code inspects the header by
# hand, which ignores q-values:
#
#     async def show(request):
#         accept = request.headers.get("accept", "")
#         if "application/json" in accept:
#             return JSONResponse(NOTE)
#         if "text/html" in accept or "*/*" in accept:
#             return HTMLResponse(f"<h1>{NOTE['text']}</h1>")
#         return PlainTextResponse("Not Acceptable", status_code=406)
#
# Run:  pagi-server --app examples/gut-check/08-negotiation.pl --port 5000
# Try:  curl -H 'Accept: application/json' localhost:5000/note
#       curl -H 'Accept: text/html;q=0.9, application/json;q=0.5' localhost:5000/note

use v5.40;
use Future::AsyncAwait;
use PAGI::Tools qw(compose middleware respond_to response route);

my $note = { id => 1, text => 'buy milk' };

# The middleware picks the type, answers 406 when nothing fits, and sends
# Vary: Accept on every answer, so a shared cache keeps HTML and JSON apart.
async sub show ($request)
{
    return respond_to($request,
        html => sub { response('HTML', "<h1>$note->{text}</h1>") },
        json => sub { response('JSON', $note) },
    );
}

compose(routes => [route('/note' => \&show,
    middleware => [middleware('ContentNegotiation', supported_types => ['html', 'json'])])]);
