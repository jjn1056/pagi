package TodoApp::Entity::Todo;

use Moo;
use Valiant::Validations;
use experimental 'signatures';

# =============================================================================
# TodoApp::Entity::Todo - Todo item entity with Valiant validation
# =============================================================================

has 'id'        => (is => 'rw');
has 'title'     => (is => 'rw', default => '');
has 'completed' => (is => 'rw', default => 0);

validates title => (presence => 1, length => { minimum => 1, maximum => 500 });

# Returns true if this is a new (unsaved) record
sub persisted ($self) {
    return defined $self->id && length $self->id;
}

# Toggle completed status
sub toggle ($self) {
    $self->completed($self->completed ? 0 : 1);
    return $self;
}

1;
