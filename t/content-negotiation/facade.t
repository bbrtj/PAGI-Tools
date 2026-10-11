use strict;
use warnings;
use Test2::V0;
use Future;

use lib 'lib';
use PAGI::ContentNegotiation qw(content_negotiation negotiated_type respond_to);

# The facade reads the record PAGI::Middleware::ContentNegotiation writes.

sub scope_with {
    my (%record) = @_;
    return { type => 'http', 'pagi.content_negotiation' => {
        type => 'json', supported => ['html', 'json'], refusing => 1, accepted => [], %record } };
}

subtest 'construction' => sub {
    like dies { PAGI::ContentNegotiation->new({ type => 'http' }) },
        qr/\QPAGI::ContentNegotiation requires ContentNegotiation middleware (missing pagi.content_negotiation)\E/,
        'without the middleware';
    like dies { PAGI::ContentNegotiation->new({ type => 'websocket' }) },
        qr/\QPAGI::ContentNegotiation applies to HTTP requests only (scope type 'websocket')\E/,
        'on a WebSocket scope';
    my $cn = PAGI::ContentNegotiation->from_data({ type => 'html', supported => ['html', 'json'] });
    is [$cn->type, $cn->supported], ['html', 'html', 'json'], 'from_data';
    like dies { PAGI::ContentNegotiation->from_data({ type => 'html' }) },
        qr/\Qfrom_data() requires supported, a non-empty arrayref\E/, 'from_data needs supported';
};

subtest 'reading the choice' => sub {
    my $cn = content_negotiation(scope_with());
    is [$cn->type, $cn->media_type, $cn->supported], ['json', 'application/json', 'html', 'json'],
        'type as declared, media_type normalized, the declared list';
    ok $cn->is('json') && !$cn->is('html'), 'is';
    like dies { $cn->is('jsno') },
        qr/\QPAGI::ContentNegotiation: 'jsno' is not one of the declared types (html, json)\E/,
        'is croaks on an undeclared name';
    my $none = content_negotiation(scope_with(type => undef, refusing => 0));
    ok !$none->is('json') && !defined $none->media_type, 'nothing acceptable';
    is negotiated_type(scope_with()), 'json', 'negotiated_type';
};

subtest 'respond dispatches to the chosen branch only' => sub {
    my %called;
    my $result = respond_to(scope_with(),
        html => sub { $called{html}++; 'HTML' },
        json => sub { $called{json}++; 'JSON' },
    );
    is [$result, \%called], ['JSON', { json => 1 }], 'one branch, its result';
};

subtest 'respond checks its branches before any runs' => sub {
    my $ran = 0;
    my $count = sub { $ran++; 'X' };
    my @cases = (
        [[html => $count, json => $count, htlm => $count],
            qr/\Q'htlm' is not one of the declared types (html, json)\E/, 'an undeclared key'],
        [[json => $count],
            qr/\Qrespond needs a branch for every declared type; missing: html\E/, 'a missing branch'],
        [[html => $count, json => 'JSON'],
            qr/\Qthe 'json' branch must be a code reference\E/, 'a non-code value'],
        [[html => $count, json => $count, none => $count],
            qr/\Qa none branch is never called while the middleware refuses unacceptable requests\E/, 'none while refusing'],
        [[html => $count, 'json'],
            qr/\Qrespond takes name => code pairs\E/, 'an odd count'],
    );
    for my $case (@cases) {
        my ($branches, $error, $label) = @$case;
        like dies { respond_to(scope_with(), @$branches) }, $error, $label;
    }
    is $ran, 0, 'no branch ran';
};

subtest 'respond and nothing acceptable' => sub {
    my $declined = scope_with(type => undef, refusing => 0);
    like dies { respond_to($declined, html => sub {}, json => sub {}) },
        qr/\Qrespond needs a none branch when the middleware has refuse => 0\E/, 'none is required with refuse => 0';
    is respond_to($declined, html => sub { 'H' }, json => sub { 'J' }, none => sub { 'N' }), 'N',
        'and called when nothing was acceptable';
    like dies { respond_to(scope_with(type => undef), html => sub {}, json => sub {}) },
        qr/\Qnothing was acceptable, so respond has no branch to call; a refuse answer returns its response directly\E/,
        'inside a refuse answer';
};

subtest 'respond branches are synchronous' => sub {
    like dies { respond_to(scope_with(), html => sub {}, json => sub { Future->done('J') }) },
        qr/\Qthe 'json' branch returned a Future; do async work before respond_to and return a response from the branch\E/,
        'a Future is refused';
};

done_testing;
