package TodoApp::Service::Todo;

use strict;
use warnings;
use experimental 'signatures';
use parent 'PAGI::Simple::Service::PerApp';

use TodoApp::Entity::Todo;

# =============================================================================
# TodoApp::Service::Todo - Todo data operations with PubSub support
# =============================================================================
#
# PerApp (singleton) service for managing todo data.
# Publishes changes to 'todos:changes' channel for SSE updates.
#
# Usage:
#   my $todos = $c->service('Todo');
#   my @all = $todos->all;
#   my $todo = $todos->find($id);
#   $todos->save($todo);
#   $todos->toggle($id);
#   $todos->delete($id);
#
# =============================================================================

# In-memory storage
my $next_id = 1;
my %storage;

# Seed initial data
_seed() unless %storage;

sub _seed {
    _store({ id => $next_id++, title => 'Learn PAGI::Simple', completed => 0 });
    _store({ id => $next_id++, title => 'Build with htmx', completed => 0 });
    _store({ id => $next_id++, title => 'Deploy app', completed => 1 });
}

sub _store ($data) {
    $storage{$data->{id}} = $data;
}

# =============================================================================
# Query Methods
# =============================================================================

sub all ($self) {
    return map { TodoApp::Entity::Todo->new(%$_) }
           sort { $a->{id} <=> $b->{id} }
           values %storage;
}

sub active ($self) {
    return grep { !$_->completed } $self->all;
}

sub completed ($self) {
    return grep { $_->completed } $self->all;
}

sub find ($self, $id) {
    my $data = $storage{$id} or return undef;
    return TodoApp::Entity::Todo->new(%$data);
}

sub active_count ($self) {
    return scalar grep { !$_->{completed} } values %storage;
}

sub count ($self) {
    return scalar keys %storage;
}

# =============================================================================
# Mutation Methods
# =============================================================================

sub save ($self, $todo) {
    # Validate first
    return undef unless $todo->validate->valid;

    # Assign ID if new
    unless ($todo->id) {
        $todo->id($next_id++);
    }

    # Store
    $storage{$todo->id} = {
        id        => $todo->id,
        title     => $todo->title,
        completed => $todo->completed,
    };

    $self->_publish('save', $todo);
    return $todo;
}

sub toggle ($self, $id) {
    my $data = $storage{$id} or return undef;
    $data->{completed} = !$data->{completed};
    $self->_publish('toggle', $data);
    return TodoApp::Entity::Todo->new(%$data);
}

sub delete ($self, $id) {
    my $data = delete $storage{$id} or return;
    $self->_publish('delete', { id => $id });
    return 1;
}

sub clear_completed ($self) {
    for my $id (keys %storage) {
        delete $storage{$id} if $storage{$id}{completed};
    }
    $self->_publish('clear', {});
}

sub toggle_all ($self) {
    my $all_done = !grep { !$_->{completed} } values %storage;
    $_->{completed} = !$all_done for values %storage;
    $self->_publish('toggle_all', {});
}

# =============================================================================
# Factory Methods
# =============================================================================

sub new_todo ($self) {
    return TodoApp::Entity::Todo->new;
}

sub build ($self, $data = {}) {
    return TodoApp::Entity::Todo->new(%$data);
}

# =============================================================================
# Field Validation (for inline htmx validation)
# =============================================================================

sub validate_field ($self, $field, $value) {
    my $todo = TodoApp::Entity::Todo->new($field => $value);
    $todo->validate;
    return $todo->errors->messages_for($field);
}

# =============================================================================
# PubSub Integration
# =============================================================================

sub _publish ($self, $action, $data) {
    my $app = $self->app;
    return unless $app;

    $app->pubsub->publish('todos:changes', { action => $action });
}

1;
