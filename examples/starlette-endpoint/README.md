# Starlette's HTTPEndpoint, ported

Starlette's class-based endpoint example and its PAGI port, side by side.

## Starlette

```python
import uvicorn
from starlette.applications import Starlette
from starlette.endpoints import HTTPEndpoint
from starlette.responses import JSONResponse
from starlette.routing import Route


# 1. Subclass HTTPEndpoint to handle specific HTTP methods
class MyHttpRoute(HTTPEndpoint):
    async def get(self, request):
        return JSONResponse({"message": "This handled a GET request!"})

    async def post(self, request):
        # Optional: Parse JSON body if needed via: data = await request.json()
        return JSONResponse({"message": "This handled a POST request!"})


# 2. Add the class directly to Route() as the endpoint
# (Note: You do not pass the methods=[] argument here; HTTPEndpoint handles it automatically)
routes = [
    Route("/httpp", endpoint=MyHttpRoute),
]

# 3. Create the Starlette application
app = Starlette(debug=True, routes=routes)

if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=8000)
```

## PAGI

```perl
package MyHttpRoute {
    use v5.40;
    use parent 'PAGI::Endpoint::HTTP';
    use Future::AsyncAwait;
    use PAGI::Tools qw(response);

    async sub get ($self, $request) {
        return response('JSON', { message => 'This handled a GET request!' });
    }

    async sub post ($self, $request) {
        # Optional: parse a JSON body if needed: my $data = await $request->json;
        return response('JSON', { message => 'This handled a POST request!' });
    }
}

package main;
use PAGI::Tools qw(compose endpoint route);

compose(routes => [
    route('/httpp' => endpoint('MyHttpRoute')),
]);
```

`endpoint('MyHttpRoute')` names the class, as `Route("/httpp",
endpoint=MyHttpRoute)` does, and like Starlette there is no `methods`
argument: the route asks the class. The class is defined in this file, so
there is nothing to load; a class in `lib/` is loaded by name. `pagi-server`
plays uvicorn's part.

## Run it

```bash
pagi-server --app examples/starlette-endpoint/app.pl --port 5000
```

## What differs

| | Starlette | PAGI |
| --- | --- | --- |
| `PUT /httpp` | 405, `Allow: GET, POST` | 405, `Allow: GET, HEAD, OPTIONS, POST` |
| `OPTIONS /httpp` | 405 (no `options` method) | 204 with `Allow` |
| who answers the 405 | the endpoint | the Router, from the class's methods; the endpoint's `method_not_allowed` answers when it is mounted or routed with `methods => '*'` |
| the endpoint object | built for every request | built once; a class that wants one per request says so with `BUILD_APP` (see `examples/endpoint-lifecycle`) |

`examples/endpoint-lifecycle` shows the other lifecycles with the same
`endpoint()` spelling.
