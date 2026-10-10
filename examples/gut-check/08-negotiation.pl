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
use PAGI::Tools qw(compose response route);

my $note = { id => 1, text => 'buy milk' };

# Every answer from this URL depends on Accept, the 406 and the no-Accept
# default included, so each one says so: a shared cache then keeps the HTML
# and the JSON apart.
my @vary = (Vary => 'Accept');

async sub show ($request)
{
    my $type = $request->preferred_type('html', 'json')
        // return response('Text', 'Not Acceptable', status => 406, headers => [@vary]);

    return $type eq 'json'
        ? response('JSON', $note, headers => [@vary])
        : response('HTML', "<h1>$note->{text}</h1>", headers => [@vary]);
}

compose(routes => [route('/note' => \&show)]);
