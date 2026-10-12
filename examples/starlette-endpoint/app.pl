#!/usr/bin/env perl
#
# Starlette's class-based HTTP endpoint, ported. The Python is in README.md.
#
# Run:  pagi-server --app examples/starlette-endpoint/app.pl --port 5000
# Try:  curl -i localhost:5000/httpp
#       curl -i -X POST localhost:5000/httpp
#       curl -i -X PUT localhost:5000/httpp        # 405, with Allow
#       curl -I localhost:5000/httpp               # HEAD: get answers, no body
#       curl -i -X OPTIONS localhost:5000/httpp    # 204, with Allow

use v5.40;

# 1. Subclass PAGI::Endpoint::HTTP to handle specific HTTP methods.
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

# 2. Name the class at the route with endpoint(). No methods option: the
#    route asks the class which methods it answers.
# 3. compose() builds the application; pagi-server runs it.
compose(routes => [
    route('/httpp' => endpoint('MyHttpRoute')),
]);
