#!/usr/bin/env perl

# =============================================================================
# Todo App Example
#
# A complete TodoMVC-style application demonstrating:
# - PAGI::Simple View layer with Template::EmbeddedPerl
# - htmx for SPA-like interactions
# - Valiant forms for validation
# - Service layer for data operations
# - SSE for live updates
# - Progressive enhancement (works without JavaScript)
#
# Run with: pagi-server --app examples/view-todo/app.pl
# =============================================================================

use strict;
use warnings;
use experimental 'signatures';
use Future::AsyncAwait;

use lib 'lib';
use lib 'examples/view-todo/lib';

use PAGI::Simple;

my $app = PAGI::Simple->new(
    name      => 'Todo App',
    # namespace derived from name: 'TodoApp'
    share     => 'htmx',
    views     => {
        directory => './templates',
        roles     => ['PAGI::Simple::View::Role::Valiant'],
        preamble  => 'use experimental "signatures";',
    },
);

# =============================================================================
# Home Page - List All Todos
# =============================================================================

$app->get('/' => sub ($c) {
    my $todos = $c->service('Todo');
    $c->render('index',
        todos    => [$todos->all],
        new_todo => $todos->new_todo,
        active   => $todos->active_count,
        filter   => 'home',
    );
})->name('home');

# Filter: Active only
$app->get('/active' => sub ($c) {
    my $todos = $c->service('Todo');
    $c->render('index',
        todos    => [$todos->active],
        new_todo => $todos->new_todo,
        active   => $todos->active_count,
        filter   => 'active',
    );
})->name('active');

# Filter: Completed only
$app->get('/completed' => sub ($c) {
    my $todos = $c->service('Todo');
    $c->render('index',
        todos    => [$todos->completed],
        new_todo => $todos->new_todo,
        active   => $todos->active_count,
        filter   => 'completed',
    );
})->name('completed');

# =============================================================================
# CRUD Operations
# =============================================================================

# Create new todo
$app->post('/todos' => async sub ($c) {
    my $todos = $c->service('Todo');
    my $new_todo = $todos->new_todo;

    # Use structured_body for Rails-style strong parameters
    # namespace_for accepts the model instance - no hardcoded class name needed
    my $data = (await $c->structured_body)
        ->namespace_for($new_todo)
        ->permitted('title')
        ->to_hash;

    my $todo = $todos->build($data);

    if ($todos->save($todo)) {
        if ($c->req->is_htmx) {
            # Return fresh form + trigger refresh
            $c->hx_trigger('todoAdded');
            $c->render('todos/_form', todo => $todos->new_todo);
        } else {
            $c->redirect('/');
        }
    } else {
        # Validation failed - re-render form with errors
        if ($c->req->is_htmx) {
            $c->render('todos/_form', todo => $todo);
        } else {
            $c->render('index',
                todos    => [$todos->all],
                new_todo => $todo,
                active   => $todos->active_count,
                filter   => 'home',
            );
        }
    }
})->name('todos_create');

# Toggle completion
$app->patch('/todos/:id/toggle' => async sub ($c) {
    my $id = $c->path_params->{id};
    my $todos = $c->service('Todo');
    my $todo = $todos->toggle($id);

    return $c->status(404)->html('<span class="error">Todo not found</span>') unless $todo;

    $c->hx_trigger('todoToggled');
    await $c->render_or_redirect('/', 'todos/_item', todo => $todo);
})->name('todo_toggle');

# Edit form (for inline editing)
$app->get('/todos/:id/edit' => sub ($c) {
    my $id = $c->path_params->{id};
    my $todos = $c->service('Todo');
    my $todo = $todos->find($id);

    return $c->status(404)->html('<span class="error">Todo not found</span>') unless $todo;

    $c->render('todos/_edit_form', todo => $todo);
})->name('todo_edit');

# Update todo
$app->patch('/todos/:id' => async sub ($c) {
    my $id = $c->path_params->{id};
    my $todos = $c->service('Todo');
    my $todo = $todos->find($id);

    return $c->status(404)->html('<span class="error">Todo not found</span>') unless $todo;

    # Use structured_body for Rails-style strong parameters
    # namespace_for accepts the model instance we already fetched
    my $data = (await $c->structured_body)
        ->namespace_for($todo)
        ->permitted('title')
        ->to_hash;

    $todo->title($data->{title} // $todo->title);

    if ($todo->validate->valid) {
        $todos->save($todo);
        $c->hx_trigger('todoUpdated');
        await $c->render_or_redirect('/', 'todos/_item', todo => $todo);
    } else {
        await $c->render_or_redirect('/', 'todos/_edit_form', todo => $todo);
    }
})->name('todo_update');

# Delete todo
$app->delete('/todos/:id' => async sub ($c) {
    my $id = $c->path_params->{id};
    my $todos = $c->service('Todo');

    return $c->status(404)->html('<span class="error">Todo not found</span>') unless $todos->delete($id);

    $c->hx_trigger('todoDeleted');
    await $c->empty_or_redirect('/');
})->name('todo_delete');

# =============================================================================
# Bulk Operations
# =============================================================================

# Clear all completed
$app->post('/todos/clear-completed' => async sub ($c) {
    my $todos = $c->service('Todo');
    $todos->clear_completed;

    $c->hx_trigger('todosCleared');
    await $c->render_or_redirect('/', 'todos/_list',
        todos  => [$todos->all],
        active => $todos->active_count,
        filter => 'home',
    );
})->name('todos_clear');

# Toggle all
$app->post('/todos/toggle-all' => async sub ($c) {
    my $todos = $c->service('Todo');
    $todos->toggle_all;

    $c->hx_trigger('todosToggled');
    await $c->render_or_redirect('/', 'todos/_list',
        todos  => [$todos->all],
        active => $todos->active_count,
        filter => 'home',
    );
})->name('todos_toggle_all');

# =============================================================================
# SSE Live Updates
# =============================================================================

$app->sse('/todos/live' => sub ($sse) {
    # Send initial connected message
    $sse->send_event(event => 'connected', data => 'ok');

    # Subscribe to changes
    $sse->subscribe('todos:changes' => sub ($msg) {
        # Trigger refresh on any change
        $sse->send_event(event => 'refresh', data => $msg->{action} // 'update');
    });
});

# =============================================================================
# Inline Validation
# =============================================================================

$app->post('/validate/:field' => async sub ($c) {
    my $field = $c->path_params->{field};

    # Use structured_body for Rails-style strong parameters
    my $data = (await $c->structured_body)
        ->namespace_for('TodoApp::Entity::Todo')
        ->permitted($field)
        ->to_hash;

    my $value = $data->{$field} // '';
    my @errors = $c->service('Todo')->validate_field($field, $value);

    if (@errors) {
        $c->html(qq{<span class="error">@{[join(', ', @errors)]}</span>});
    } else {
        $c->html(qq{<span class="valid">Looks good!</span>});
    }
})->name('validate_field');

$app->to_app;
