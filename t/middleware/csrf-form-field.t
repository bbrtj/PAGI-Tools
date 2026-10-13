use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;

use lib 'lib';
use PAGI::CSRF qw(csrf);
use PAGI::Middleware::CSRF;
use PAGI::Test::Client;
use PAGI::Tools qw(compose middleware response route);

# The handler reports the recorded failure and, for each comma-separated
# name in ?read=, what that body reader gives -- or how it dies -- after the
# middleware has run.
my $called = 0;
my %reader = (
    form    => async sub { (await $_[0]->form_params)->get('title') // '' },
    strict  => async sub { (await $_[0]->form_params(strict => 1))->get('title') // '' },
    body    => async sub { await $_[0]->body },
    json    => async sub { (await $_[0]->json)->{title} },
    uploads => async sub { scalar((await $_[0]->uploads)->values) },
    stream  => async sub { $_[0]->body_stream; 'streams' },
    mstream => async sub { $_[0]->multipart_stream; 'streams' },
);
async sub report {
    my ($request) = @_;
    $called++;
    my @parts = ('failure=' . (csrf($request)->failure // 'none'));
    for my $name (split /,/, $request->query_param('read') // '') {
        my $got = await $reader{$name}->($request)
            ->else(sub { my ($error) = @_; Future->done('dies: ' . ($error =~ s/ at \S+ line \d+.*//sr)) });
        push @parts, "$name=$got";
    }
    return response('Text', join ' | ', @parts);
}

sub client_with {
    my (%csrf) = @_;
    return PAGI::Test::Client->new(app => compose(
        routes     => [route('/' => \&report, methods => [qw(GET POST PUT PATCH DELETE)])],
        middleware => [middleware('CSRF', %csrf)],
    ));
}

# A client holding its CSRF cookie, and the token in it.
sub primed {
    my $client = client_with(@_);
    $client->get('/');
    return ($client, $client->cookie('csrf_token'));
}

my $boundary = 'XyZ';
my %multipart = ('Content-Type' => "multipart/form-data; boundary=$boundary");
my %urlencoded = ('Content-Type' => 'application/x-www-form-urlencoded');
sub multipart_body {
    my (%field) = @_;
    return join "\r\n",
        (map { ("--$boundary", qq{Content-Disposition: form-data; name="$_"}, '', $field{$_}) } sort keys %field),
        ("--$boundary", 'Content-Disposition: form-data; name="file"; filename="a.txt"',
            'Content-Type: text/plain', '', 'x' x 100),
        "--$boundary--", '';
}

subtest 'a urlencoded form with the right field passes, and its parse stays cached' => sub {
    my ($client, $token) = primed();
    my $res = $client->post('/?read=form,strict,body,stream,mstream',
        form => { csrf_token => $token, title => "h\xc3\xa9" });    # UTF-8, as a browser sends it
    is $res->status, 200, 'no header: the field is read';
    is $res->text, join(' | ', 'failure=none', "form=h\x{e9}", "strict=h\x{e9}",
        "body=csrf_token=$token&title=h%C3%A9",
        'stream=dies: Body already consumed; streaming not available',
        'mstream=dies: Body already consumed; multipart_stream() not available'),
        'form_params and body come from the cache; the streams die';
};

subtest 'a missing, empty or wrong field is refused' => sub {
    my ($client, $token) = primed();
    $called = 0;
    my $res = $client->post('/', form => { title => 'hi' });
    is [$res->status, $res->text], [403, 'CSRF token validation failed'], 'no field: the default refusal';
    is $client->post('/', form => { csrf_token => '', title => 'hi' })->status, 403, 'an empty field';
    is $client->post('/', form => { csrf_token => 'forged' })->status, 403, 'a wrong field';
    is $called, 0, 'the application is never called';

    my ($open) = primed(refuse => 0);
    is $open->post('/', form => { title => 'hi' })->text, 'failure=missing_token', 'refuse => 0: missing_token';
    is $open->post('/', form => { csrf_token => '' })->text, 'failure=missing_token', 'an empty field is missing';
    is $open->post('/', form => { csrf_token => 'forged' })->text, 'failure=mismatch', 'a wrong field is a mismatch';
};

subtest 'a non-empty header decides, and the body is never read' => sub {
    my ($client, $token) = primed();
    my $res = $client->post('/?read=stream', form => { title => 'hi' }, headers => { 'X-CSRF-Token' => $token });
    is [$res->status, $res->text], [200, 'failure=none | stream=streams'], 'right header, no field: unread';

    $res = $client->post('/', form => { csrf_token => $token }, headers => { 'X-CSRF-Token' => 'forged' });
    is $res->status, 403, 'wrong header with the right field: refused';
    my ($open, $token0) = primed(refuse => 0);
    is $open->post('/?read=stream', form => { csrf_token => $token0 }, headers => { 'X-CSRF-Token' => 'forged' })->text,
        'failure=mismatch | stream=streams', 'the header decided and the body is unread';

    $res = $client->post('/?read=form', form => { csrf_token => $token, title => 'hi' }, headers => { 'X-CSRF-Token' => '' });
    is [$res->status, $res->text], [200, 'failure=none | form=hi'], 'an empty header is absent: the field decides';
};

subtest 'a multipart form is read the same way' => sub {
    my ($client, $token) = primed();
    my $res = $client->post('/?read=form,uploads,body,mstream',
        body => multipart_body(csrf_token => $token, title => 'hi'), headers => \%multipart);
    is $res->status, 200, 'the right field passes';
    is $res->text, join(' | ', 'failure=none', 'form=hi', 'uploads=1',
        'body=dies: The raw body of a multipart request is not kept; read it with form_params and uploads',
        'mstream=dies: Body already consumed; multipart_stream() not available'),
        'form_params and uploads come from the cache';
    is $client->post('/', body => multipart_body(title => 'hi'), headers => \%multipart)->status, 403,
        'no field: refused';

    $res = $client->post('/', body => multipart_body(csrf_token => $token, big => 'x' x (1024 * 1024 + 10)),
        headers => \%multipart);
    is [$res->status, $res->text], [413, 'Form field too large (max 1048576 bytes)'],
        "PAGI::Request's default limits apply: Compose answers the body error";
};

subtest 'form_field names the field; undef reads only the header' => sub {
    my ($named, $token) = primed(form_field => 'authenticity_token');
    is $named->post('/', form => { authenticity_token => $token })->status, 200, 'another name is read';
    is $named->post('/', form => { csrf_token => $token })->status, 403, 'and the default name is not';

    my ($header_only, $token1) = primed(form_field => undef);
    is $header_only->post('/', form => { csrf_token => $token1 })->status, 403, 'undef: the field is not read';
    my ($open, $token0) = primed(form_field => undef, refuse => 0);
    is $open->post('/?read=stream', form => { csrf_token => $token0 })->text,
        'failure=missing_token | stream=streams', 'and the body is left unread';
    is $header_only->post('/?read=stream', form => { title => 'hi' }, headers => { 'X-CSRF-Token' => $token1 })->text,
        'failure=none | stream=streams', 'the header still passes';
};

subtest 'a JSON body is never read: it needs the header' => sub {
    my ($client, $token) = primed();
    my $res = $client->post('/?read=json', json => { title => 'hi' }, headers => { 'X-CSRF-Token' => $token });
    is [$res->status, $res->text], [200, 'failure=none | json=hi'], 'with the header: the handler reads the JSON';
    is $client->post('/', json => { csrf_token => $token })->status, 403, 'without it: refused, a token in the JSON or not';
    my ($open, $token0) = primed(refuse => 0);
    is $open->post('/?read=stream', json => { csrf_token => $token0 })->text,
        'failure=missing_token | stream=streams', 'and its body is unread';
};

subtest 'nothing is read for a safe method, a cross-site request, or with no token to match' => sub {
    my ($open, $token) = primed(refuse => 0);
    is $open->get('/?read=stream', form => { csrf_token => $token })->text,
        'failure=none | stream=streams', 'GET';
    is $open->post('/?read=stream', form => { csrf_token => $token }, headers => { 'Sec-Fetch-Site' => 'cross-site' })->text,
        'failure=cross_origin | stream=streams', 'cross-site';
    my $fresh = client_with(refuse => 0);
    is $fresh->post('/?read=stream', form => { csrf_token => 'guess' })->text,
        'failure=missing_cookie | stream=streams', 'no stored token';
};

subtest 'a refused form goes to refuse, and refuse => 0 reports it' => sub {
    my ($client, $token) = primed(refuse => response('JSON', { detail => 'nope' }, status => 403));
    my $res = $client->post('/', form => { csrf_token => 'forged' });
    is [$res->status, $res->text], [403, '{"detail":"nope"}'], 'the refuse application answers';

    my $app = compose(
        routes     => [route('/' => sub { response('Text', csrf($_[0])->valid) }, methods => ['GET', 'POST'])],
        middleware => [middleware('CSRF', refuse => 0)],
    );
    my $open = PAGI::Test::Client->new(app => $app);
    $open->get('/');
    is $open->post('/', form => { csrf_token => $open->cookie('csrf_token') })->text, 1, 'valid with the right field';
    is $open->post('/', form => {})->text, 0, 'not valid without it';
};

subtest 'under session => 1 the field matches the session token' => sub {
    my $app = compose(
        routes     => [route('/' => sub { response('Text', $_[0]->method eq 'GET' ? csrf($_[0])->token : 'saved') },
            methods => ['GET', 'POST'])],
        middleware => [middleware('Session'), middleware('CSRF', session => 1)],
    );
    like warning { $app->to_app }, qr/\APAGI::Middleware::Session: no store given/,
        'the default session store says so';
    my $client = PAGI::Test::Client->new(app => $app);
    my $token = $client->get('/')->text;
    is $client->post('/', form => { csrf_token => $token })->text, 'saved', 'the session token in the field passes';
    is $client->post('/', form => {})->status, 403, 'a missing one is refused';
};

subtest 'form_field must be a field name or undef' => sub {
    for my $bad ('', []) {
        like dies { PAGI::Middleware::CSRF->new(form_field => $bad) },
            qr/\ACSRF form_field must be a field name, like csrf_token, or undef to read only the header/,
            'form_field => ' . (ref $bad ? 'a reference' : "''") . ' dies';
    }
    ok lives { PAGI::Middleware::CSRF->new(form_field => undef) }, 'undef lives';
};

subtest 'every unsafe method reads the form' => sub {
    my ($client, $token) = primed();
    my ($open, $token0) = primed(refuse => 0);
    for my $method (qw(put patch delete)) {
        is $client->$method('/', form => { csrf_token => $token })->status, 200, uc($method) . ': the field is read';
        is $open->$method('/', form => { csrf_token => $token0 })->text, 'failure=none',
            uc($method) . ': no failure recorded';
    }
};

subtest "a malformed multipart body is the client's 400, answered by Compose" => sub {
    my ($client) = primed();
    my $res = $client->post('/', body => '', headers => { 'Content-Type' => 'multipart/form-data' });
    is [$res->status, $res->text], [400, 'No boundary found in Content-Type'], 'no boundary';
    $res = $client->post('/', body => '', headers => \%multipart);
    is [$res->status, $res->text], [400, 'The multipart request body could not be parsed.'], 'an empty body';
};

subtest 'nothing to read is missing_token' => sub {
    my ($client) = primed();
    is $client->post('/', body => '', headers => \%urlencoded)->status, 403, 'an empty form body is refused';
    my ($open, $token0) = primed(refuse => 0);
    is $open->post('/', body => '', headers => \%urlencoded)->text, 'failure=missing_token',
        'an empty form body records missing_token';
    is $open->post("/?csrf_token=$token0", body => '', headers => \%urlencoded)->text, 'failure=missing_token',
        'a token in the query string is never read';
};

subtest 'under session => 1 a planted csrf_token cookie does not stand in for the session token' => sub {
    my $app = compose(
        routes     => [route('/' => \&report, methods => ['GET', 'POST'])],
        middleware => [middleware('Session'), middleware('CSRF', session => 1)],
    );
    # The default session store warns once per process, so only an earlier
    # subtest may have heard it.
    my $warnings = warnings { $app->to_app };
    ok !(grep { !/\APAGI::Middleware::Session: no store given/ } @$warnings),
        'nothing warns but the default session store';
    my $client = PAGI::Test::Client->new(app => $app);
    $client->get('/');
    my $planted = 'a' x 64;
    $client->set_cookie(csrf_token => $planted);
    is $client->post('/', form => { csrf_token => $planted })->status, 403,
        'a field matching the planted cookie is refused';
};

subtest 'a repeated csrf_token field: the last value decides' => sub {
    my ($client, $token) = primed();
    is $client->post('/', form => [[csrf_token => 'forged'], [csrf_token => $token]])->status, 200,
        'the right token last passes';
    my ($open, $token0) = primed(refuse => 0);
    is $open->post('/', form => [[csrf_token => $token0], [csrf_token => 'forged']])->text, 'failure=mismatch',
        'a forged token last is a mismatch';
};

subtest 'the form media type is matched in any case and with parameters' => sub {
    my ($client, $token) = primed();
    my $res = $client->post('/?read=form', body => "csrf_token=$token&title=hi",
        headers => { 'Content-Type' => 'Application/X-WWW-Form-Urlencoded; charset=UTF-8' });
    is [$res->status, $res->text], [200, 'failure=none | form=hi'], 'read, and cached for the handler';
};

subtest 'a csrf_token file part is an upload, not the field' => sub {
    my ($open, $token) = primed(refuse => 0);
    my $body = join "\r\n", "--$boundary",
        qq{Content-Disposition: form-data; name="csrf_token"; filename="token.txt"},
        'Content-Type: text/plain', '', $token, "--$boundary--", '';
    is $open->post('/?read=uploads', body => $body, headers => \%multipart)->text,
        'failure=missing_token | uploads=1', 'missing_token, and the part is still in uploads';
};

subtest 'bytes that are not UTF-8 in the field are a mismatch, not an error' => sub {
    my ($open) = primed(refuse => 0);
    my $res = $open->post('/', body => 'csrf_token=' . ('%FF' x 64), headers => \%urlencoded);
    is [$res->status, $res->text], [200, 'failure=mismatch'], 'decoded loosely and compared';
};

# An application that reads the body from $receive itself, as one written to
# the PAGI spec does, and answers with what it read.
async sub echo_body {
    my ($scope, $receive, $send) = @_;
    my $body = '';
    if ($scope->{method} ne 'GET') {
        while (1) {
            my $event = await $receive->();
            last unless $event->{type} eq 'http.request';
            $body .= $event->{body} // '';
            last unless $event->{more};
        }
    }
    await $send->({ type => 'http.response.start', status => 200, headers => [['content-type', 'text/plain']] });
    await $send->({ type => 'http.response.body', body => "read: $body", more => 0 });
}

sub primed_native {
    my (%csrf) = @_;
    my $client = PAGI::Test::Client->new(app => PAGI::Middleware::CSRF->new(%csrf)->wrap(\&echo_body));
    $client->get('/');
    return ($client, $client->cookie('csrf_token'));
}

subtest 'an application reading $receive gets the whole body the middleware read' => sub {
    my ($client, $token) = primed_native();
    my $form = "csrf_token=$token&title=hi";
    is [map { $_->status, $_->text } $client->post('/', body => $form, headers => \%urlencoded)],
        [200, "read: $form"], 'a urlencoded form';

    my $multipart = multipart_body(csrf_token => $token, title => 'hi');
    is [map { $_->status, $_->text } $client->post('/', body => $multipart, headers => \%multipart)],
        [200, "read: $multipart"], 'a multipart form';

    my ($open) = primed_native(refuse => 0);
    is $open->post('/', body => 'title=hi', headers => \%urlencoded)->text, 'read: title=hi',
        'under refuse => 0, a form without the field';
};

subtest "a refused form's body reaches refuse" => sub {
    require PAGI::Utils;
    my ($client) = primed_native(refuse => PAGI::Utils::as_app_object(\&echo_body));
    is $client->post('/', body => 'csrf_token=forged', headers => \%urlencoded)->text,
        'read: csrf_token=forged', 'the refuse application reads it';
};

subtest 'body_buffer makes the buffer for each request whose body is read' => sub {
    require PAGI::Utils::ReceiveBuffer::TempFile;
    my @scopes;
    my ($client, $token) = primed_native(body_buffer => sub {
        push @scopes, $_[0];
        return PAGI::Utils::ReceiveBuffer::TempFile->new(spool_threshold => 0);
    });
    is $client->post('/', body => 'title=hi', headers => { %urlencoded, 'X-CSRF-Token' => $token })->text,
        'read: title=hi', 'a request with the header';
    is scalar @scopes, 0, 'is not read, so no buffer is made';

    is $client->post('/', body => "csrf_token=$token", headers => \%urlencoded)->text,
        "read: csrf_token=$token", 'a request with the field';
    is [map { $_->{type} } @scopes], ['http'], 'gets one buffer, made from its scope';

    like dies { PAGI::Middleware::CSRF->new(body_buffer => 'big') },
        qr/CSRF body_buffer must be a coderef that returns a buffer/, 'body_buffer must be a coderef';
};

done_testing;
