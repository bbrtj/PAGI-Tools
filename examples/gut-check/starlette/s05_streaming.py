# Starlette counterpart of ../05-streaming.pl
import asyncio
import json

from starlette.applications import Starlette
from starlette.responses import StreamingResponse
from starlette.routing import Route


async def ticks(request):
    async def gen():
        for n in range(5):
            if await request.is_disconnected():
                break
            yield json.dumps({"tick": n}) + "\n"
            await asyncio.sleep(0.2)

    return StreamingResponse(gen(), media_type="application/x-ndjson")


class TSVResponse(StreamingResponse):
    media_type = "text/tab-separated-values; charset=utf-8"

    def __init__(self, rows, **kwargs):
        async def lines():
            for row in rows:
                yield "\t".join("" if f is None else str(f) for f in row) + "\n"

        super().__init__(lines(), **kwargs)


async def report(request):
    return TSVResponse([["city", "population"], ["Lisbon", 545000], ["Kraków", 800000]])


app = Starlette(routes=[Route("/ticks", ticks), Route("/report.tsv", report)])
