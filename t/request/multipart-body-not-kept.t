use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use PAGI::Request;

# A multipart body streams to its parts and is not kept whole; asking for it
# afterwards is a mistake to say, not an empty answer.
my $boundary = 'XyZ';
my $multipart = "--$boundary\r\nContent-Disposition: form-data; name=\"name\"\r\n\r\nada\r\n--$boundary--\r\n";
my @events = ({ type => 'http.request', body => $multipart, more => 0 });
my $request = PAGI::Request->new({
    type => 'http', method => 'POST', path => '/',
    headers => [['content-type', "multipart/form-data; boundary=$boundary"], ['content-length', length $multipart]],
}, async sub { shift @events // { type => 'http.disconnect' } });

my $form = $request->form_params->get;
is $form->get('name'), 'ada', 'the form is read';
like dies { $request->body->get },
    qr/The raw body of a multipart request is not kept; read it with form_params and uploads/,
    'body says the raw bytes were not kept';

done_testing;
