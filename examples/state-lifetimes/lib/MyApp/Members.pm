package MyApp::Members;
use v5.40;
use Future::AsyncAwait;
use Future::IO;

our $LOOKUPS = 0;    # how many times a viewer was looked up, for the tests

sub new ($class, %args) { bless { db => $args{db} }, $class }

sub all ($self) { $self->{db}->rows }

# A query: async, as it would be against a real database.
async sub find_by_token ($self, $token) {
    $LOOKUPS++;
    await Future::IO->sleep(0);
    return undef unless defined $token;
    my ($member) = grep { ($_->{token} // '') eq $token } $self->{db}->rows->@*;
    return $member;
}

async sub email_taken ($self, $email) {
    await Future::IO->sleep(0);
    return !!grep { lc $_->{email} eq lc $email } $self->{db}->rows->@*;
}

sub add ($self, %member) {
    push $self->{db}->rows->@*, {%member};
    return {%member};
}

1;
