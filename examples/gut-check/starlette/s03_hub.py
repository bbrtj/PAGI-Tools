# Starlette counterpart of ../03-broadcast-hub.pl (no broadcaster package,
# no sse-starlette: SSE is a StreamingResponse fed by a per-client queue)
import asyncio

from starlette.applications import Starlette
from starlette.responses import JSONResponse, StreamingResponse
from starlette.routing import Route, WebSocketRoute
from starlette.websockets import WebSocketDisconnect

listeners = {}


def publish(source, text):
    for deliver in list(listeners.values()):
        deliver(f"{source}: {text}")
    return len(listeners)


async def chat(websocket):
    await websocket.accept()
    queue = asyncio.Queue()
    listeners[id(websocket)] = queue.put_nowait

    async def pump():
        while True:
            await websocket.send_text(await queue.get())

    sender = asyncio.create_task(pump())
    try:
        while True:
            publish("chat", await websocket.receive_text())
    except WebSocketDisconnect:
        pass
    finally:
        sender.cancel()
        listeners.pop(id(websocket), None)


async def watch(request):
    queue = asyncio.Queue()
    key = object()
    listeners[key] = queue.put_nowait

    async def events():
        try:
            while True:
                line = await queue.get()
                yield f"event: line\ndata: {line}\n\n"
        finally:
            listeners.pop(key, None)

    return StreamingResponse(events(), media_type="text/event-stream")


async def announce(request):
    count = publish("announce", (await request.body()).decode())
    return JSONResponse({"delivered_to": count}, status_code=202)


app = Starlette(routes=[
    WebSocketRoute("/chat", chat),
    Route("/watch", watch),
    Route("/announce", announce, methods=["POST"]),
])
