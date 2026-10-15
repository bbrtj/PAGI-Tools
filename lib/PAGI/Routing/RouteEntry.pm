package PAGI::Routing::RouteEntry;

use strict;
use warnings;

# One row of route_table, built by PAGI::Routing::Resolver. Every accessor
# returns fresh copies of the entry's own containers; the values inside them
# are the originals.
sub _new {
    my ($class, %fields) = @_;
    return bless {%fields}, $class;
}

# The same entry with middleware outside it: Compose's application middleware.
sub _with_outer_middleware {
    my ($self, @middleware) = @_;
    return (ref $self)->_new(%$self, middleware => [@middleware, @{$self->{middleware}}]);
}

sub template { $_[0]{template} }
sub pattern  { $_[0]{pattern} }
sub kind     { $_[0]{kind} }
sub name     { $_[0]{name} }
sub address  { $_[0]{address} }
sub desc     { $_[0]{desc} }
sub node     { $_[0]{node} }

sub methods {
    my ($self) = @_;
    return undef unless $self->{kind} eq 'route';
    return $self->{node}->methods;
}

sub parameters { [ @{$_[0]{parameters}} ] }

sub constraints {
    my ($self) = @_;
    return { map { $_ => [ @{$self->{constraints}{$_}} ] } keys %{$self->{constraints}} };
}

sub middleware { [ @{$_[0]{middleware}} ] }

sub meta { [ map { +{%$_} } @{$_[0]{meta}} ] }

1;

__END__

=head1 NAME

PAGI::Routing::RouteEntry - One route of an application, described

=head1 SYNOPSIS

    for my $entry ($app->route_table) {
        my $methods = $entry->methods;    # an arrayref, '*', or undef (WebSocket, SSE, mount)
        printf "%-10s %-30s %s\n",
            join(',', ref $methods ? @$methods : ($methods // $entry->kind)),
            $entry->template, $entry->desc // '';
    }

=head1 DESCRIPTION

C<route_table> on L<PAGI::Routing::Router> and L<PAGI::Compose> returns one
of these for each route in the tree, depth-first in declaration order: what
a tool that describes an application (an OpenAPI document, a route listing,
a test of an application's surface) reads, from the public API.

A Mount whose application is a Router contributes that Router's routes, not
an entry of its own. A Mount whose application is anything else (a coderef,
an application object, a Compose) is one entry of kind C<mount>: a separate
application (see L<PAGI::Routing/mount>), which describes itself -- a Compose
with its own C<route_table>, a L<PAGI::App::Compose> with
C<< composition->route_table >>, their templates relative to the mount. A child
Router placed under two mounts gives two entries per route, with the same
C<node>.

Every read of an accessor returns fresh copies of the entry's own arrayrefs
and hashrefs, so changing what one read returned changes neither a later read
nor another entry. The copies are shallow: middleware descriptions, types,
Regexps and coderefs, and every value nested inside a C<meta> hash, are the
originals, shared with the Router. "Read-only" means the entry's own
containers.

=head1 ACCESSORS

=head2 template

The path template: every mount's path composed with the route's, each
capture written C<{name}> and its inline constraint left out
(C</people/{person_id}/notes/{id}>). A wildcard is written C<{name}> too
(C</files/*path> is C</files/{path}>); C<pattern> tells them apart. A route
C<'/'> inside C<mount('/api', ...)> is C</api/>, as its match record and
C<path_for> have it.

=head2 pattern

The composed declared path, inline constraints kept
(C</people/{person_id:&PersonId}/notes/{id:&Int}>): the same string as the
C<route> of the C<pagi.routing> match record at request time.

=head2 kind

C<route> (HTTP), C<websocket>, C<sse>, or C<mount> for a mounted application,
which is separate from this one.

=head2 methods

For a C<route>, what its C<methods> returns: an arrayref (C<GET> implies
C<HEAD>), or the string C<'*'> for an unrestricted route. C<undef> for the
other kinds.

=head2 name

The route's own name as declared, or C<undef>.

=head2 address

Its absolute address: the key in C<named_routes> and what C<path_for> takes;
C<undef> if unnamed.

=head2 desc

The route's C<desc>.

=head2 parameters

The capture names, the enclosing mounts' first, in order.

=head2 constraints

A hashref from each capture name to an arrayref of its constraints I<as
declared>, in declaration order (an inline constraint, then an explicit
C<constraints> entry): a Type::Tiny (or any check) object, a Regexp or
coderef as given, or for an inline regexp (C<{id:\d+}>) its source string. A
capture with none is absent. Unlike a Route's own C<constraints> (explicit
entries only, one value each), this lists every constraint on every capture.

=head2 middleware

An arrayref of the L<PAGI::Routing::Middleware> descriptions that run around
the route, outermost first, in the order they are applied: through
L<PAGI::Compose>, its application middleware; then each enclosing Router's
middleware and each enclosing Mount's, outer to inner; then the route's own.
Compose's own error handling, completion guard and HEAD handling are not
descriptions and do not appear.

=head2 meta

An arrayref of each level's C<meta> hashref (see L<PAGI::Routing/meta>),
outermost mount first, the route's last; levels without C<meta> are left
out. The consumer decides how to merge them.

=head2 node

The L<PAGI::Routing::Route>, or for C<mount> the L<PAGI::Routing::Mount>.

=head1 SEE ALSO

L<PAGI::Routing>, L<PAGI::Routing::Router>, L<PAGI::Compose>

=cut
