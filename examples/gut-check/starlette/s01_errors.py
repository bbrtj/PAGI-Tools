# Starlette counterpart of ../01-errors-as-responses.pl
from starlette.applications import Starlette
from starlette.exceptions import HTTPException
from starlette.responses import JSONResponse
from starlette.routing import Route

NOTES = {1: {"id": 1, "text": "buy milk"}}


def find_note(note_id):
    if note_id not in NOTES:
        raise HTTPException(status_code=404, detail=f"no such note: {note_id}")
    return NOTES[note_id]


async def show(request):
    return JSONResponse(find_note(int(request.path_params["id"])))


async def boom(request):
    raise RuntimeError("an ordinary bug")


async def http_exception(request, exc):
    return JSONResponse({"error": exc.detail}, status_code=exc.status_code)


app = Starlette(
    routes=[Route("/notes/{id}", show), Route("/boom", boom)],
    exception_handlers={HTTPException: http_exception},
)
