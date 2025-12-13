#!/usr/bin/env perl

# =============================================================================
# Integration Tests for Todo App Example
#
# Tests the complete Todo app with all CRUD operations, htmx requests,
# filtering, and progressive enhancement.
# =============================================================================

use strict;
use warnings;
use Test2::V0;
use experimental 'signatures';
use Future;

# Set up lib paths before loading app modules
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../examples/view-todo/lib";

# =============================================================================
# Helper Functions - Same pattern as core tests
# =============================================================================

sub simulate_request ($app, %opts) {
    my $method = $opts{method} // 'GET';
    my $path   = $opts{path} // '/';
    my $query  = $opts{query_string} // '';
    my $headers = $opts{headers} // [];
    my $body   = $opts{body};

    my @sent;
    my $scope = {
        type         => 'http',
        method       => $method,
        path         => $path,
        query_string => $query,
        headers      => $headers,
    };

    my $body_consumed = 0;
    my $receive = sub {
        if (!$body_consumed && defined $body) {
            $body_consumed = 1;
            return Future->done({
                type => 'http.request',
                body => $body,
            });
        }
        return Future->done({ type => 'http.request' });
    };

    my $send = sub ($event) {
        push @sent, $event;
        return Future->done;
    };

    my $pagi_app = $app->to_app;
    $pagi_app->($scope, $receive, $send)->get;

    return \@sent;
}

sub get_status ($sent) { $sent->[0]{status} }
sub get_body ($sent)   { $sent->[1]{body} // '' }
sub get_headers ($sent) { $sent->[0]{headers} // [] }

sub get_header ($sent, $name) {
    my $headers = get_headers($sent);
    for my $h (@$headers) {
        return $h->[1] if lc($h->[0]) eq lc($name);
    }
    return undef;
}

# =============================================================================
# Load modules and setup
# =============================================================================

use TodoApp::Entity::Todo;
use TodoApp::Service::Todo;
pass('Loaded TodoApp::Entity::Todo');
pass('Loaded TodoApp::Service::Todo');

# =============================================================================
# Entity Tests
# =============================================================================

subtest 'Todo entity - basic attributes' => sub {
    my $todo = TodoApp::Entity::Todo->new(
        id        => 1,
        title     => 'Test Todo',
        completed => 0,
    );

    is $todo->id, 1, 'id accessor works';
    is $todo->title, 'Test Todo', 'title accessor works';
    is $todo->completed, 0, 'completed accessor works';
    ok $todo->persisted, 'persisted returns true when id is set';
};

subtest 'Todo entity - validation' => sub {
    my $todo = TodoApp::Entity::Todo->new(title => '');
    ok !$todo->validate->valid, 'empty title fails validation';

    my @errors = $todo->errors->messages_for('title');
    ok @errors > 0, 'has error messages for title';

    my $valid_todo = TodoApp::Entity::Todo->new(title => 'Valid Title');
    ok $valid_todo->validate->valid, 'valid title passes validation';
};

subtest 'Todo entity - toggle' => sub {
    my $todo = TodoApp::Entity::Todo->new(
        title     => 'Test',
        completed => 0,
    );

    $todo->toggle;
    is $todo->completed, 1, 'toggle sets completed to 1';

    $todo->toggle;
    is $todo->completed, 0, 'toggle sets completed back to 0';
};

# =============================================================================
# Service Tests (without HTTP)
# =============================================================================

subtest 'Todo service - all() returns todos' => sub {
    my $service = TodoApp::Service::Todo->new;

    my @todos = $service->all;
    ok @todos >= 1, 'has todos';

    my ($first) = @todos;
    isa_ok $first, ['TodoApp::Entity::Todo'], 'returns Entity objects';
};

subtest 'Todo service - find() returns single todo' => sub {
    my $service = TodoApp::Service::Todo->new;
    my @all = $service->all;
    my $first_id = $all[0]->id;

    my $found = $service->find($first_id);
    ok $found, 'found todo by id';
    is $found->id, $first_id, 'correct id';

    my $not_found = $service->find(99999);
    ok !$not_found, 'returns undef for non-existent id';
};

subtest 'Todo service - save() creates new todo' => sub {
    my $service = TodoApp::Service::Todo->new;
    my $count_before = $service->count;

    my $todo = $service->new_todo;
    $todo->title('New Todo Item');

    my $result = $service->save($todo);
    ok $result, 'save returns todo on success';
    ok $todo->id, 'todo has id assigned';

    is $service->count, $count_before + 1, 'count increased';
};

subtest 'Todo service - save() validates' => sub {
    my $service = TodoApp::Service::Todo->new;
    my $count_before = $service->count;

    my $todo = $service->new_todo;
    $todo->title('');  # Invalid

    my $result = $service->save($todo);
    ok !$result, 'save returns undef on validation failure';
    is $service->count, $count_before, 'count unchanged';
};

subtest 'Todo service - toggle() works' => sub {
    my $service = TodoApp::Service::Todo->new;
    my @all = $service->all;
    my $todo = $all[0];
    my $was_completed = $todo->completed;

    my $toggled = $service->toggle($todo->id);
    ok $toggled, 'toggle returns todo';
    is $toggled->completed, ($was_completed ? 0 : 1), 'completed status flipped';
};

subtest 'Todo service - delete() works' => sub {
    my $service = TodoApp::Service::Todo->new;

    # Create a todo to delete
    my $todo = $service->new_todo;
    $todo->title('To be deleted');
    $service->save($todo);
    my $id = $todo->id;
    my $count_before = $service->count;

    ok $service->delete($id), 'delete returns true';
    is $service->count, $count_before - 1, 'count decreased';
    ok !$service->find($id), 'todo no longer found';
};

subtest 'Todo service - active() and completed() filters' => sub {
    my $service = TodoApp::Service::Todo->new;

    my @active = $service->active;
    my @completed = $service->completed;
    my @all = $service->all;

    is scalar(@active) + scalar(@completed), scalar(@all),
        'active + completed = all';

    for my $todo (@active) {
        ok !$todo->completed, 'active todos are not completed';
    }

    for my $todo (@completed) {
        ok $todo->completed, 'completed todos are completed';
    }
};

subtest 'Todo service - active_count()' => sub {
    my $service = TodoApp::Service::Todo->new;
    my @active = $service->active;

    is $service->active_count, scalar(@active), 'active_count matches active()';
};

subtest 'Todo service - validate_field()' => sub {
    my $service = TodoApp::Service::Todo->new;

    my @errors = $service->validate_field('title', '');
    ok @errors > 0, 'empty title has errors';

    @errors = $service->validate_field('title', 'Valid Title');
    is scalar(@errors), 0, 'valid title has no errors';
};

# =============================================================================
# HTTP Integration Tests using actual app.pl
# =============================================================================

use PAGI::Simple;

# Change to the project root directory for templates to work
chdir "$FindBin::Bin/../..";

# Helper to initialize services (mimics lifespan.startup)
sub init_app_services ($app) {
    $app->_init_services();
}

my $pagi_app;
subtest 'Create PAGI::Simple app with service discovery' => sub {
    $pagi_app = PAGI::Simple->new(
        name      => 'Todo App',
        # namespace derived from name: 'TodoApp'
        home      => "$FindBin::Bin/../../examples/view-todo",
        lib       => "$FindBin::Bin/../../examples/view-todo/lib",
        share     => 'htmx',
        views     => {
            directory => "$FindBin::Bin/../../examples/view-todo/templates",
            roles     => ['PAGI::Simple::View::Role::Valiant'],
            preamble  => 'use experimental "signatures";',
        },
    );

    # Init services (mimics lifespan.startup)
    init_app_services($pagi_app);

    # Home page route
    $pagi_app->get('/' => sub ($c) {
        my $todos = $c->service('Todo');
        $c->render('index',
            todos    => [$todos->all],
            new_todo => $todos->new_todo,
            active   => $todos->active_count,
            filter   => 'home',
        );
    })->name('home');

    # Active filter
    $pagi_app->get('/active' => sub ($c) {
        my $todos = $c->service('Todo');
        $c->render('index',
            todos    => [$todos->active],
            new_todo => $todos->new_todo,
            active   => $todos->active_count,
            filter   => 'active',
        );
    })->name('active');

    # Completed filter
    $pagi_app->get('/completed' => sub ($c) {
        my $todos = $c->service('Todo');
        $c->render('index',
            todos    => [$todos->completed],
            new_todo => $todos->new_todo,
            active   => $todos->active_count,
            filter   => 'completed',
        );
    })->name('completed');

    ok $pagi_app, 'created PAGI::Simple app';
};

subtest 'HTTP - Home page renders' => sub {
    my $sent = simulate_request($pagi_app, path => '/');

    is get_status($sent), 200, 'status 200';
    my $body = get_body($sent);
    like $body, qr/<h1>todos<\/h1>/, 'has todos header';
    like $body, qr/todo-list/, 'has todo list';
    like $body, qr/new-todo/, 'has new todo input';
};

subtest 'HTTP - Active filter' => sub {
    my $sent = simulate_request($pagi_app, path => '/active');

    is get_status($sent), 200, 'status 200';
    like get_body($sent), qr/filters/, 'has filters';
};

subtest 'HTTP - Completed filter' => sub {
    my $sent = simulate_request($pagi_app, path => '/completed');

    is get_status($sent), 200, 'status 200';
};

subtest 'HTTP - 404 for unknown route' => sub {
    my $sent = simulate_request($pagi_app, path => '/nonexistent');

    is get_status($sent), 404, 'status 404';
};

done_testing;
