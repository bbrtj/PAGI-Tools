#!/usr/bin/env perl
#
# Streaming responses: a slow NDJSON feed and a custom streaming format.
#
# The producer is handed a Writer rather than being pulled like a generator:
# each awaited write is a backpressure point, and the producer can see a
# disconnect and stop. A format is a Stream subclass with format_item, so the
# producer writes items, not bytes. PAGI::Test::Client drives the producer's
# sleeps, so this app is tested in-process like the others.
#
# The Starlette version is in README.md.
#
# Run:  pagi-server --app examples/gut-check/05-streaming.pl --port 5000
# Try:  curl -N localhost:5000/ticks
#       curl -N localhost:5000/report.tsv

use v5.40;
use utf8;
use Future::AsyncAwait;
use Future::IO;    # pagi-server binds the implementation

# A streaming format of our own: tab-separated rows.
package Report::TSV {
    use v5.40;
    use parent 'PAGI::Response::Stream';
    use Encode qw(encode);

    sub default_content_type { 'text/tab-separated-values; charset=utf-8' }

    sub format_item ($self, $row) {
        return encode('UTF-8', join("\t", map { $_ // '' } @$row) . "\n");
    }
}

package main;

use PAGI::Tools qw(compose response route);

async sub ticks ($request) {
    return response('NDJSON', async sub ($writer) {
        for my $n (0 .. 4) {
            last if $writer->is_disconnected;
            await $writer->write_item({ tick => $n });
            await Future::IO->sleep(0.2);
        }
    });
}

async sub report ($request) {
    my @rows = (['city', 'population'], ['Lisbon', 545_000], ['Kraków', 800_000]);
    return Report::TSV->new(async sub ($writer) {
        for my $row (@rows) {
            await $writer->write_item($row);
        }
    });
}

compose(
    routes => [
        route('/ticks' => \&ticks),
        route('/report.tsv' => \&report),
    ],
);
