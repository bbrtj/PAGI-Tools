package MyApp::DB;
use v5.40;
use Future::AsyncAwait;
use Future::IO;

# A stand-in for a database connection: opened once per worker, with a
# moment of real I/O, and closed at shutdown. The rows are the members.
async sub connect ($class) {
    await Future::IO->sleep(0.01);
    return bless {
        open => 1,
        rows => [ { name => 'Ada', email => 'ada@example.com', token => 'ada-token' } ],
    }, $class;
}

sub rows       ($self) { $self->{rows} }
sub is_open    ($self) { $self->{open} }
sub disconnect ($self) { $self->{open} = 0 }

1;
