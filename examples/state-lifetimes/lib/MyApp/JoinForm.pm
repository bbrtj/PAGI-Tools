package MyApp::JoinForm;
use v5.40;
use Future::AsyncAwait;

# One submission's values and errors: a new object each time, so one
# submission's errors never reach the next.
sub new ($class, %args) { bless { members => $args{members}, errors => {} }, $class }

sub errors ($self) { $self->{errors} }

# Resolves to the new member, or nothing when there are errors.
async sub process ($self, $params) {
    my %value = map { $_ => $params->get($_) // '' } qw(name email);
    $self->{errors}{name} = 'is required' unless length $value{name};
    if ($value{email} !~ /\A[^@\s]+@[^@\s]+\z/) {
        $self->{errors}{email} = 'is not an email address';
    }
    elsif (await $self->{members}->email_taken($value{email})) {
        $self->{errors}{email} = 'is already a member';
    }
    return if %{ $self->{errors} };
    return $self->{members}->add(%value);
}

1;
