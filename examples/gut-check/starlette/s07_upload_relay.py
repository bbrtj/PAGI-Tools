# Starlette counterpart of ../07-upload-relay.pl
#
# /sha256 works. /relay and /shout do not, under uvicorn or the TestClient
# (checked with Starlette 1.7.0): /relay returns 0 bytes and /shout hangs.
# StreamingResponse runs listen_for_disconnect, a loop of `await receive()`,
# alongside the body generator (starlette/responses.py), and that loop takes
# the request-body messages request.stream() is waiting for. Starlette's
# usual answer is to read the whole body before returning the response.
import hashlib

from starlette.applications import Starlette
from starlette.responses import JSONResponse, StreamingResponse
from starlette.routing import Route


async def relay(request):
    return StreamingResponse(request.stream(), media_type="application/octet-stream")


async def shout(request):
    async def upper():
        async for chunk in request.stream():
            yield chunk.upper()

    return StreamingResponse(upper(), media_type="application/octet-stream")


async def sha256(request):
    sha, size = hashlib.sha256(), 0
    async for chunk in request.stream():
        sha.update(chunk)
        size += len(chunk)
    return JSONResponse({"bytes": size, "sha256": sha.hexdigest()})


app = Starlette(routes=[
    Route("/relay", relay, methods=["POST"]),
    Route("/shout", shout, methods=["POST"]),
    Route("/sha256", sha256, methods=["POST"]),
])
