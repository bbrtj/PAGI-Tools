# Starlette counterpart of ../04-everyday-middleware.pl
import os
import time

from starlette.applications import Starlette
from starlette.middleware import Middleware
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import PlainTextResponse
from starlette.routing import Route


class Timing(BaseHTTPMiddleware):
    async def dispatch(self, request, call_next):
        started = time.perf_counter()
        response = await call_next(request)
        response.headers["Server-Timing"] = f"app;dur={1000 * (time.perf_counter() - started):.1f}"
        return response


class Maintenance(BaseHTTPMiddleware):
    async def dispatch(self, request, call_next):
        if os.environ.get("MAINTENANCE") and request.url.path != "/health":
            return PlainTextResponse("back soon", status_code=503, headers={"Retry-After": "60"})
        return await call_next(request)


async def home(request):
    return PlainTextResponse("hello")


async def health(request):
    return PlainTextResponse("ok")


app = Starlette(
    routes=[Route("/", home), Route("/health", health)],
    middleware=[Middleware(Timing), Middleware(Maintenance)],
)
