package TodoApp::Todos;

use strict;
use warnings;
use parent 'PAGI::Simple::Handler';
use experimental 'signatures';
use Future::AsyncAwait;

sub routes ($class, $app, $r) {
    # Home and filters
    $r->get('/'          => '#index')->name('home');
    $r->get('/active'    => '#active')->name('active');
    $r->get('/completed' => '#completed')->name('completed');

    # CRUD with #load chain for :id routes
    $r->post('/todos'              => '#create')->name('todos_create');
    $r->patch('/todos/:id/toggle'  => '#load' => '#toggle')->name('todo_toggle');
    $r->get('/todos/:id/edit'      => '#load' => '#edit_form')->name('todo_edit');
    $r->patch('/todos/:id'         => '#load' => '#update')->name('todo_update');
    $r->delete('/todos/:id'        => '#load' => '#destroy')->name('todo_delete');

    # Bulk operations
    $r->post('/todos/clear-completed' => '#clear_completed')->name('todos_clear');
    $r->post('/todos/toggle-all'      => '#toggle_all')->name('todos_toggle_all');

    # Validation
    $r->post('/validate/:field' => '#validate_field')->name('validate_field');
}

# Middleware: load todo by :id
async sub load ($self, $c) {
    my $id = $c->path_params->{id};
    my $todo = $c->app->service('Todo')->find($id);

    return $c->status(404)->html('<span class="error">Todo not found</span>')
        unless $todo;

    $c->stash->{todo} = $todo;
}

# Index views
async sub index ($self, $c) {
    my $todos = $c->app->service('Todo');
    $c->render('index',
        todos    => [$todos->all],
        new_todo => $todos->new_todo,
        active   => $todos->active_count,
        filter   => 'home',
    );
}

async sub active ($self, $c) {
    my $todos = $c->app->service('Todo');
    $c->render('index',
        todos    => [$todos->active],
        new_todo => $todos->new_todo,
        active   => $todos->active_count,
        filter   => 'active',
    );
}

async sub completed ($self, $c) {
    my $todos = $c->app->service('Todo');
    $c->render('index',
        todos    => [$todos->completed],
        new_todo => $todos->new_todo,
        active   => $todos->active_count,
        filter   => 'completed',
    );
}

# CRUD operations
async sub create ($self, $c) {
    my $todos = $c->app->service('Todo');
    my $new_todo = $todos->new_todo;

    my $data = (await $c->structured_body)
        ->namespace_for($new_todo)
        ->permitted('title')
        ->to_hash;

    my $todo = $todos->build($data);

    if ($todos->save($todo)) {
        if ($c->req->is_htmx) {
            $c->hx_trigger('todoAdded');
            $c->render('todos/_form', todo => $todos->new_todo);
        } else {
            $c->redirect('/');
        }
    } else {
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
}

async sub toggle ($self, $c) {
    my $todos = $c->app->service('Todo');
    my $todo = $c->stash->{todo};
    $todo = $todos->toggle($todo->{id});

    $c->hx_trigger('todoToggled');
    await $c->render_or_redirect('/', 'todos/_item', todo => $todo);
}

async sub edit_form ($self, $c) {
    $c->render('todos/_edit_form', todo => $c->stash->{todo});
}

async sub update ($self, $c) {
    my $todos = $c->app->service('Todo');
    my $todo = $c->stash->{todo};

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
}

async sub destroy ($self, $c) {
    my $todo = $c->stash->{todo};
    $c->app->service('Todo')->delete($todo->{id});
    $c->hx_trigger('todoDeleted');
    await $c->empty_or_redirect('/');
}

# Bulk operations
async sub clear_completed ($self, $c) {
    my $todos = $c->app->service('Todo');
    $todos->clear_completed;

    $c->hx_trigger('todosCleared');
    await $c->render_or_redirect('/', 'todos/_list',
        todos  => [$todos->all],
        active => $todos->active_count,
        filter => 'home',
    );
}

async sub toggle_all ($self, $c) {
    my $todos = $c->app->service('Todo');
    $todos->toggle_all;

    $c->hx_trigger('todosToggled');
    await $c->render_or_redirect('/', 'todos/_list',
        todos  => [$todos->all],
        active => $todos->active_count,
        filter => 'home',
    );
}

# Field validation
async sub validate_field ($self, $c) {
    my $field = $c->path_params->{field};

    my $data = (await $c->structured_body)
        ->namespace_for('TodoApp::Entity::Todo')
        ->permitted($field)
        ->to_hash;

    my $value = $data->{$field} // '';
    my @errors = $c->app->service('Todo')->validate_field($field, $value);

    if (@errors) {
        $c->html(qq{<span class="error">@{[join(', ', @errors)]}</span>});
    } else {
        $c->html(qq{<span class="valid">Looks good!</span>});
    }
}

1;
