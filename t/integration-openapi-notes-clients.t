use strict;
use warnings;
use Test2::V0;
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use HTTP::Tiny;
use IO::Socket::INET;
use POSIX qw(WNOHANG);
use lib "$Bin/../lib";
use lib "$Bin/lib";
use PAGITest::CurrentServer qw(current_server_unavailable);

# The acceptance check for PAGI::Routing::OpenAPI: the document
# examples/openapi-notes serves, handed to real client generators, gives
# clients that work against the running API. Two generators,
# openapi-python-client (through uv) and openapi-generator's python client
# (through Docker); each generated client is driven through the whole API.

plan skip_all => 'set RELEASE_TESTING to run the generated-client check' unless $ENV{RELEASE_TESTING};
plan skip_all => 'examples/openapi-notes requires Perl 5.40' if $] < 5.040;
plan skip_all => 'Server integration tests not supported on Windows' if $^O eq 'MSWin32';
my $unavailable = current_server_unavailable();
plan skip_all => $unavailable if $unavailable;
plan skip_all => 'uv is not on PATH' unless grep { -x File::Spec->catfile($_, 'uv') } File::Spec->path;
plan skip_all => 'Docker is not running' unless system('docker info >/dev/null 2>&1') == 0;

my $root   = abs_path("$Bin/..");
my $server = abs_path(dirname($INC{'PAGI/Server.pm'}) . '/../..');
my $bin    = "$server/bin/pagi-server";
plan skip_all => "no bin/pagi-server beside the loaded PAGI::Server ($bin)" unless -f $bin;

my $tmp = tempdir(CLEANUP => 1);

# Runs a command with stdout and stderr captured separately: (exit status,
# stdout, stderr).
sub run_command {
    my (@command) = @_;
    my ($out, $err) = ("$tmp/stdout", "$tmp/stderr");
    my $pid = fork // die "fork: $!";
    if (!$pid) {
        open STDOUT, '>', $out or die "stdout: $!";
        open STDERR, '>', $err or die "stderr: $!";
        exec @command or die "exec $command[0]: $!";
    }
    waitpid $pid, 0;
    my $status = $? >> 8;
    my $slurp = sub { open my $fh, '<', $_[0] or return ''; local $/; return scalar <$fh> };
    return ($status, $slurp->($out), $slurp->($err));
}

sub write_file {
    my ($path, $content) = @_;
    open my $fh, '>', $path or die "$path: $!";
    print {$fh} $content;
    close $fh or die "$path: $!";
}

my $port = do {
    my $probe = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 1)
        or die "probe socket: $!";
    my $p = $probe->sockport;
    close $probe;
    $p;
};
my $base = "http://127.0.0.1:$port";
my $log  = "$tmp/server.log";

# Whatever happens after the fork -- a die, a failed start -- the server does
# not outlive the test.
my $server_pid;
END { if ($server_pid) { kill 'KILL', $server_pid; waitpid $server_pid, 0 } }

my $pid = fork // die "fork: $!";
if (!$pid) {
    open STDOUT, '>', $log or die "log: $!";
    open STDERR, '>&', \*STDOUT or die "log: $!";
    exec $^X, "-I$root/lib", "-I$server/lib", $bin,
        '-I', "$root/examples/openapi-notes/lib",
        '--app', "$root/examples/openapi-notes/lib/NotesApp.pm",
        '--host', '127.0.0.1', '--port', $port
        or die "exec pagi-server: $!";
}
$server_pid = $pid;

sub server_log { open my $fh, '<', $log or return ''; local $/; return scalar <$fh> }

my $up;
for (1 .. 100) {
    last if waitpid($pid, WNOHANG) == $pid;
    if (IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Timeout => 1)) { $up = 1; last }
    select undef, undef, undef, 0.1;
}
unless ($up) {
    # This file fails; the rest of a prove run goes on.
    fail("the hero starts on port $port");
    diag server_log();
    done_testing;
    exit;
}

my $res = HTTP::Tiny->new->get("$base/openapi.json");
is($res->{status}, 200, 'the hero serves its OpenAPI document') or diag server_log();
write_file("$tmp/openapi.json", $res->{content});

write_file("$tmp/script1.py", <<'PY');
import sys
from notes_client import AuthenticatedClient, Client
from notes_client.api.default import get_notes_list, post_notes_create, get_notes_show, delete_notes_remove
from notes_client.models import NewNote, Note

base = sys.argv[1]
guest = Client(base_url=base)
writer = AuthenticatedClient(base_url=base, token="writer")
reader = AuthenticatedClient(base_url=base, token="reader")

assert get_notes_list.sync(client=guest) == []
note = post_notes_create.sync(client=writer, body=NewNote(text="buy milk"))
assert isinstance(note, Note) and note.text == "buy milk" and isinstance(note.id, int), note
assert get_notes_show.sync(client=guest, id=note.id) == note
assert post_notes_create.sync_detailed(client=reader, body=NewNote(text="no")).status_code == 403
assert delete_notes_remove.sync_detailed(client=writer, id=note.id).status_code == 204
assert get_notes_show.sync_detailed(client=guest, id=note.id).status_code == 404
print("ok")
PY

write_file("$tmp/script2.py", <<'PY');
import sys
import openapi_client
from openapi_client.rest import ApiException
from openapi_client.models.new_note import NewNote

def api(token=None):
    configuration = openapi_client.Configuration(host=sys.argv[1], access_token=token)
    return openapi_client.DefaultApi(openapi_client.ApiClient(configuration))

guest, writer, reader = api(), api("writer"), api("reader")
assert guest.get_notes_list() == []
note = writer.post_notes_create(NewNote(text="buy milk"))
assert note.text == "buy milk" and isinstance(note.id, int), note
assert guest.get_notes_show(note.id) == note
try:
    reader.post_notes_create(NewNote(text="no"))
    raise SystemExit("reader was not refused")
except ApiException as e:
    assert e.status == 403, e.status
writer.delete_notes_remove(note.id)
try:
    guest.get_notes_show(note.id)
    raise SystemExit("deleted note still shown")
except ApiException as e:
    assert e.status == 404, e.status
print("ok")
PY

my $user = join ':', $<, (split ' ', $()[0];
my @clients = (
    ['openapi-python-client',
        [qw(uvx openapi-python-client generate), '--path', "$tmp/openapi.json", '--output-path', "$tmp/py1", '--overwrite'],
        "$tmp/py1", "$tmp/script1.py"],
    ['openapi-generator (python)',
        ['docker', 'run', '--rm', '--user', $user, '-v', "$tmp:/local", 'openapitools/openapi-generator-cli',
         'generate', '-i', '/local/openapi.json', '-g', 'python', '-o', '/local/py2'],
        "$tmp/py2", "$tmp/script2.py"],
);

for my $client (@clients) {
    my ($name, $generate, $dir, $script) = @$client;
    subtest $name => sub {
        my ($status, $out, $err) = run_command(@$generate);
        is($status, 0, 'generates a client from the document') or diag "stdout:\n$out\nstderr:\n$err";
        ($status, $out, $err) = run_command(qw(uv run --no-project --with), $dir, 'python', $script, $base);
        is([$status, $out], [0, "ok\n"], 'which works against the running API, call by call')
            or diag "stdout:\n$out\nstderr:\n$err\nserver log:\n" . server_log();
    };
}

kill 'TERM', $pid;
my $gone;
for (1 .. 100) {
    if (waitpid($pid, WNOHANG) == $pid) { $gone = 1; last }
    select undef, undef, undef, 0.1;
}
unless ($gone) { kill 'KILL', $pid; waitpid $pid, 0 }
undef $server_pid;
ok($gone, 'the server stops on TERM');
ok(!IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Timeout => 1), 'and its port is closed');

done_testing;
