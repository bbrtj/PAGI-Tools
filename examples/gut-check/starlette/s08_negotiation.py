# Starlette counterpart of ../08-negotiation.pl: header inspected by hand,
# which ignores quality values (no negotiation helper ships with Starlette).
from starlette.applications import Starlette
from starlette.responses import HTMLResponse, JSONResponse, PlainTextResponse
from starlette.routing import Route

NOTE = {"id": 1, "text": "buy milk"}


async def show(request):
    accept = request.headers.get("accept", "")
    if "application/json" in accept:
        return JSONResponse(NOTE)
    if "text/html" in accept or "*/*" in accept:
        return HTMLResponse(f"<h1>{NOTE['text']}</h1>")
    return PlainTextResponse("Not Acceptable", status_code=406)


app = Starlette(routes=[Route("/note", show)])
