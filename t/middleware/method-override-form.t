use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;

use lib 'lib';
use PAGI::Middleware::MethodOverride;
use PAGI::Test::Client;
use PAGI::Tools qw(compose middleware response route);
use PAGI::Utils::ReceiveBuffer::TempFile;

# MethodOverride takes the method from a POST's _method form field, as an
# HTML form sends it, besides the header and the query string. It reads the
# form through record_receive, so the application still receives the body.

# An application that reads the body from $receive itself and answers with
# the method it was given and the body it read.
async sub echo {
    my ($scope, $receive, $send) = @_;
    my $body = '';
    while (1) {
        my $event = await $receive->();
        last unless $event->{type} eq 'http.request';
        $body .= $event->{body} // '';
        last unless $event->{more};
    }
    await $send->({ type => 'http.response.start', status => 200, headers => [['content-type', 'text/plain']] });
    await $send->({ type => 'http.response.body', body => "$scope->{method} $body", more => 0 });
}

sub native {
    return PAGI::Test::Client->new(app => PAGI::Middleware::MethodOverride->new(@_)->wrap(\&echo));
}

my %urlencoded = ('Content-Type' => 'application/x-www-form-urlencoded');
my $boundary = 'XyZ';
my %multipart = ('Content-Type' => "multipart/form-data; boundary=$boundary");
sub multipart_body {
    my (%field) = @_;
    return join "\r\n",
        (map { ("--$boundary", qq{Content-Disposition: form-data; name="$_"}, '', $field{$_}) } sort keys %field),
        "--$boundary--", '';
}

subtest 'a form field overrides a POST, and the application receives the whole body' => sub {
    my $client = native();
    is $client->post('/', body => '_method=DELETE&title=hi', headers => \%urlencoded)->text,
        'DELETE _method=DELETE&title=hi', 'urlencoded';
    my $body = multipart_body(_method => 'PATCH', title => 'hi');
    is $client->post('/', body => $body, headers => \%multipart)->text, "PATCH $body", 'multipart';
    is $client->post('/', body => '_method=delete', headers => \%urlencoded)->text, 'DELETE _method=delete',
        'the value is case-insensitive';
};

subtest 'the header, then the form field, then the query' => sub {
    my $client = native();
    is $client->post('/', body => '_method=DELETE', headers => { %urlencoded, 'X-HTTP-Method-Override' => 'PUT' })->text,
        'PUT _method=DELETE', 'the header beats the field';
    is $client->post('/?_method=PUT', body => '_method=DELETE', headers => \%urlencoded)->text,
        'DELETE _method=DELETE', 'the field beats the query';
    is $client->post('/?_method=PUT', body => 'title=hi', headers => \%urlencoded)->text,
        'PUT title=hi', 'a form without the field falls back to the query';
};

subtest 'what is left alone' => sub {
    my $client = native();
    is $client->post('/', body => '{"_method":"DELETE"}', headers => { 'Content-Type' => 'application/json' })->text,
        'POST {"_method":"DELETE"}', 'a JSON body is never read';
    is $client->put('/', body => '_method=DELETE', headers => \%urlencoded)->text, 'PUT _method=DELETE',
        'only a POST is overridden';
    is $client->post('/', body => '_method=GET', headers => \%urlencoded)->text, 'POST _method=GET',
        'a method outside allowed_methods is ignored';
};

subtest 'check_form => 0 never reads the body; check_param => 0 ignores the query' => sub {
    is native(check_form => 0)->post('/?_method=PUT', body => '_method=DELETE', headers => \%urlencoded)->text,
        'PUT _method=DELETE', 'check_form => 0: the field is ignored, the query still counts';
    is native(check_param => 0)->post('/?_method=PUT', body => '_method=DELETE', headers => \%urlencoded)->text,
        'DELETE _method=DELETE', 'check_param => 0: the query is ignored, the field still counts';
    is native(check_param => 0)->post('/?_method=PUT', body => 'title=hi', headers => \%urlencoded)->text,
        'POST title=hi', 'and without the field nothing overrides';
};

subtest 'body_buffer makes the buffer for each request whose body is read' => sub {
    my @scopes;
    my $client = native(body_buffer => sub {
        push @scopes, $_[0];
        return PAGI::Utils::ReceiveBuffer::TempFile->new(spool_threshold => 0);
    });
    $client->post('/', body => '_method=DELETE', headers => { %urlencoded, 'X-HTTP-Method-Override' => 'PUT' });
    $client->post('/', body => '{}', headers => { 'Content-Type' => 'application/json' });
    is scalar @scopes, 0, 'not for a request with the header, nor for a body that is not a form';
    is $client->post('/', body => '_method=DELETE', headers => \%urlencoded)->text, 'DELETE _method=DELETE',
        'a form';
    is [map { $_->{type} } @scopes], ['http'], 'gets one buffer, made from its scope';
    like dies { PAGI::Middleware::MethodOverride->new(body_buffer => 'big') },
        qr/MethodOverride body_buffer must be a coderef that returns a buffer/, 'body_buffer must be a coderef';
    like dies { PAGI::Middleware::MethodOverride->new(check_form => 2) },
        qr/MethodOverride check_form must be 0 or 1/, 'check_form must be 0 or 1';
};

# A Compose route reporting the method and what PAGI::Request gives it.
my %reader = (
    form   => async sub { (await $_[0]->form_params)->get('title') // '' },
    stream => async sub { $_[0]->body_stream; 'streams' },
);
async sub report {
    my ($request) = @_;
    my @parts = ($request->method);
    for my $name (split /,/, $request->query_param('read') // '') {
        my $got = await $reader{$name}->($request)
            ->else(sub { my ($error) = @_; Future->done('dies: ' . ($error =~ s/ at \S+ line \d+.*//sr)) });
        push @parts, "$name=$got";
    }
    return response('Text', join ' | ', @parts);
}

sub composed {
    my (@middleware) = @_;
    return PAGI::Test::Client->new(app => compose(
        routes     => [route('/' => \&report, methods => [qw(POST PUT PATCH DELETE)])],
        middleware => \@middleware,
    ));
}

subtest 'the parse is shared with the application, so a form below it cannot be streamed' => sub {
    my $client = composed(middleware('MethodOverride'));
    is $client->post('/?read=form,stream', body => '_method=DELETE&title=hi', headers => \%urlencoded)->text,
        'DELETE | form=hi | stream=dies: Body already consumed; streaming not available',
        'form_params reuses the parse; body_stream dies';
    is composed(middleware('MethodOverride', check_form => 0))
        ->post('/?read=stream', body => 'title=hi', headers => \%urlencoded)->text,
        'POST | stream=streams', 'under check_form => 0 the form streams';
};

subtest 'a form the parse rejects is not an override; the application meets the error itself' => sub {
    my $client = composed(middleware('MethodOverride'));
    my $res = $client->post('/?read=form', body => '', headers => \%multipart);
    is $res->text, 'POST | form=dies: The multipart request body could not be parsed.',
        'an empty multipart body: no override, and the read in the handler dies with the parse error';
};

subtest 'with CSRF, in either order, a form carries both _method and csrf_token' => sub {
    for my $order (['CSRF', 'MethodOverride'], ['MethodOverride', 'CSRF']) {
        my $client = composed(map { middleware($_) } @$order);
        $client->put('/');    # any response sets the CSRF cookie
        my $token = $client->cookie('csrf_token');
        my $res = $client->post('/?read=form', body => "_method=DELETE&csrf_token=$token&title=hi",
            headers => \%urlencoded);
        is [$res->status, $res->text], [200, 'DELETE | form=hi'], join(' outside ', @$order);
        is $client->post('/', body => '_method=DELETE&csrf_token=forged', headers => \%urlencoded)->status, 403,
            join(' outside ', @$order) . ': a wrong token is still refused';
    }
};

done_testing;
