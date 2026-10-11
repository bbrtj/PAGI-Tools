package Tiny::Plugin::Timing;

# A Tiny plugin: Server-Timing on every response, as an `around` hook. A
# plugin is a package with a register method; it uses the same DSL pieces
# an application does.

use v5.40;
use Future::AsyncAwait;
use Time::HiRes qw(time);

sub register ($class, $app, %opt) {
    my $name = $opt{name} // 'app';
    push @{ $app->{around} }, async sub ($req, $next) {
        my $started = time;
        my $sent    = await $next->();
        $sent->headers->set('Server-Timing', sprintf('%s;dur=%.1f', $name, 1000 * (time - $started)));
        return $sent;
    };
    return;
}

1;
