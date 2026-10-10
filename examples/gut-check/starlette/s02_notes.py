# Starlette counterpart of ../02-notes-resource.pl
from contextlib import asynccontextmanager

from starlette.applications import Starlette
from starlette.endpoints import HTTPEndpoint
from starlette.responses import JSONResponse, Response
from starlette.routing import Route


class NoteStore:
    def __init__(self):
        self.next, self.notes = 1, {}

    def all(self):
        return [self.notes[k] for k in sorted(self.notes)]

    def find(self, note_id):
        return self.notes.get(note_id)

    def add(self, data):
        note = {"id": self.next, "text": data["text"]}
        self.notes[self.next] = note
        self.next += 1
        return note

    def remove(self, note_id):
        return self.notes.pop(note_id, None)


class Notes(HTTPEndpoint):
    async def get(self, request):
        return JSONResponse(request.app.state.notes.all())

    async def post(self, request):
        note = request.app.state.notes.add(await request.json())
        return JSONResponse(note, status_code=201,
                            headers={"Location": request.url_for("note", id=note["id"]).path})


class Note(HTTPEndpoint):
    async def get(self, request):
        note = request.app.state.notes.find(request.path_params["id"])
        if note is None:
            return JSONResponse({"error": "no such note"}, status_code=404)
        return JSONResponse(note)

    async def delete(self, request):
        if request.app.state.notes.remove(request.path_params["id"]) is None:
            return JSONResponse({"error": "no such note"}, status_code=404)
        return Response(status_code=204)


@asynccontextmanager
async def lifespan(app):
    app.state.notes = NoteStore()
    yield


app = Starlette(
    routes=[Route("/notes", Notes, name="notes"), Route("/notes/{id:int}", Note, name="note")],
    lifespan=lifespan,
)
