package NotesApp::Store;

# The application-lifetime note store. Lifespan startup builds one and puts
# it in the state every request and connection sees.

use v5.40;

sub new ($class) { bless { next => 1, notes => {}, watch_log => [] }, $class }

sub all ($self) { [ map { $self->{notes}{$_} } sort { $a <=> $b } keys $self->{notes}->%* ] }
sub find ($self, $id) { $self->{notes}{$id} }
sub add ($self, $text, $author) {
    my $id = $self->{next}++;
    return $self->{notes}{$id} = { id => $id, text => $text, author => $author };
}
sub remove ($self, $id) { delete $self->{notes}{$id} }

# Each closed watch connection records how many messages it delivered.
sub log_watch ($self, $delivered) { push $self->{watch_log}->@*, $delivered }
sub watch_log ($self) { [ $self->{watch_log}->@* ] }

1;
