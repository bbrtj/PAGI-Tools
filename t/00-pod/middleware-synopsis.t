use strict;
use warnings;
use Test2::V0;
use FindBin;

# Every bundled middleware's SYNOPSIS opens with the Compose form. Its first
# run of verbatim paragraphs, run as published, builds $app, and building the
# application constructs the middleware, so the documented arguments cannot
# drift from what the middleware accepts.

my @middleware = qw(
    AccessLog Authentication ConditionalGet ContentLength ContentNegotiation
    Cookie CORS CSRF Debug ErrorHandler ETag GZip Head Healthcheck
    HTTPSRedirect Lint Maintenance MethodOverride RateLimit RequestId
    ReverseProxy Rewrite Runtime SecurityHeaders Session SSE::Retry Static
    TrustedHosts XSendfile
);

# The SYNOPSIS's first run of verbatim paragraphs, unindented.
sub compose_form {
    my ($name) = @_;
    (my $path = $name) =~ s{::}{/}g;
    my $file = "$FindBin::Bin/../../lib/PAGI/Middleware/$path.pm";
    my $pod = do { open my $fh, '<', $file or die "$file: $!"; local $/; <$fh> };
    my ($section) = $pod =~ /^=head1 SYNOPSIS\n(.*?)^=head1 /ms;
    my @code;
    for my $paragraph (split /\n{2,}/, ($section // '') =~ s/\A\n+//r) {
        last if @code && $paragraph !~ /\A[ \t]/;
        push @code, $paragraph =~ s/^    //mgr if $paragraph =~ /\A[ \t]/;
    }
    return join "\n\n", @code;
}

for my $name (@middleware) {
    subtest $name => sub {
        my $code = compose_form($name);
        like($code, qr/middleware\('\Q$name\E'/, 'the SYNOPSIS opens with the Compose form');
        my $runs = sub {
            my $app = eval "package PAGITest::MiddlewareSynopsis::$name; $code; \$app";
            is($@, '', 'it runs as published');
            isa_ok($app, 'PAGI::Compose');
            ok(lives { $app->to_app }, 'building the application constructs the middleware')
                or note($@);
        };
        # Session's SYNOPSIS uses the default store, which announces itself.
        if ($name eq 'Session') {
            like(warnings { $runs->() }, [qr/\APAGI::Middleware::Session: no store given/], 'the default store says so');
        }
        else {
            ok(no_warnings { $runs->() }, 'without warnings');
        }
    };
}

done_testing;
