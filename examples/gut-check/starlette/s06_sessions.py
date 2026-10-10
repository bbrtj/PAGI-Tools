# Starlette counterpart of ../06-sessions.pl
from starlette.applications import Starlette
from starlette.middleware import Middleware
from starlette.middleware.sessions import SessionMiddleware
from starlette.responses import JSONResponse, PlainTextResponse, Response
from starlette.routing import Route


async def visits(request):
    request.session["visits"] = request.session.get("visits", 0) + 1
    return JSONResponse({"visits": request.session["visits"], "name": request.session.get("name")})


async def name(request):
    request.session["name"] = (await request.body()).decode()
    return Response(status_code=204)


async def strict(request):
    return PlainTextResponse(request.session["nmae"])  # a typo


app = Starlette(
    routes=[Route("/visits", visits), Route("/name", name, methods=["POST"]), Route("/strict", strict)],
    middleware=[Middleware(SessionMiddleware, secret_key="not-a-real-secret")],
)
