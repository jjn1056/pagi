#!/usr/bin/env perl

# =============================================================================
# Integration Tests for Todo App SSE Live Updates
#
# Tests the SSE endpoint for live updates when todos change.
# Verifies that:
#   1. SSE endpoint sends 'connected' event on connection
#   2. Creating a todo triggers 'refresh' event on SSE
#   3. Other mutations (toggle, delete) also trigger refresh
# =============================================================================

use strict;
use warnings;
use Test2::V0;
use experimental 'signatures';
use Future;
use Future::AsyncAwait;

# Set up lib paths before loading app modules
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../examples/view-todo/lib";

use PAGI::Simple;
use PAGI::Simple::PubSub;

# =============================================================================
# Helper Functions
# =============================================================================

# Simulate HTTP request
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

# Simulate SSE connection and return sent events
sub simulate_sse ($app, %opts) {
    my $path = $opts{path} // '/events';

    my @sent;
    my $scope = {
        type   => 'sse',
        path   => $path,
    };

    # Build event queue for receive: disconnect after handler runs
    my @events;
    push @events, { type => 'sse.disconnect' };
    my $event_index = 0;

    my $receive = sub {
        if ($event_index < @events) {
            return Future->done($events[$event_index++]);
        }
        return Future->done({ type => 'sse.disconnect' });
    };

    my $send = sub ($event) {
        push @sent, $event;
        return Future->done;
    };

    my $pagi_app = $app->to_app;
    $pagi_app->($scope, $receive, $send)->get;

    return {
        sent => \@sent,
    };
}

# Extract SSE events of type 'sse.send'
sub get_sse_events ($result) {
    return grep { $_->{type} eq 'sse.send' } @{$result->{sent}};
}

# =============================================================================
# Setup App
# =============================================================================

# Change to the project root directory for templates to work
chdir "$FindBin::Bin/../..";

# Reset pubsub singleton before tests
PAGI::Simple::PubSub->reset;

my $app;
subtest 'Setup Todo app with SSE endpoint' => sub {
    $app = PAGI::Simple->new(
        name      => 'Todo App',
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
    $app->_init_services();

    # Home page route
    $app->get('/' => sub ($c) {
        my $todos = $c->service('Todo');
        $c->render('index',
            todos    => [$todos->all],
            new_todo => $todos->new_todo,
            active   => $todos->active_count,
            filter   => 'home',
        );
    })->name('home');

    # Create todo endpoint
    $app->post('/todos' => async sub ($c) {
        my $todos = $c->service('Todo');
        my $new_todo = $todos->new_todo;

        my $data = (await $c->structured_body)
            ->namespace_for($new_todo)
            ->permitted('title')
            ->to_hash;

        my $todo = $todos->build($data);

        if ($todos->save($todo)) {
            $c->redirect('/');
        } else {
            $c->status(400)->text("Validation failed");
        }
    })->name('todos_create');

    # Toggle todo endpoint
    $app->patch('/todos/:id/toggle' => async sub ($c) {
        my $id = $c->path_params->{id};
        my $todos = $c->service('Todo');
        my $todo = $todos->toggle($id);

        return $c->status(404)->text('Not found') unless $todo;
        $c->redirect('/');
    })->name('todo_toggle');

    # Delete todo endpoint
    $app->delete('/todos/:id' => async sub ($c) {
        my $id = $c->path_params->{id};
        my $todos = $c->service('Todo');

        return $c->status(404)->text('Not found') unless $todos->delete($id);
        $c->redirect('/');
    })->name('todo_delete');

    # SSE endpoint for live updates
    $app->sse('/todos/live' => sub ($sse) {
        # Send initial connected message
        $sse->send_event(event => 'connected', data => 'ok');

        # Subscribe to changes
        $sse->subscribe('todos:changes' => sub ($msg) {
            # Trigger refresh on any change
            $sse->send_event(event => 'refresh', data => $msg->{action} // 'update');
        });
    });

    ok $app, 'created app with SSE endpoint';
};

# =============================================================================
# SSE Connection Tests
# =============================================================================

subtest 'SSE endpoint sends connected event' => sub {
    PAGI::Simple::PubSub->reset;

    my $result = simulate_sse($app, path => '/todos/live');

    # Check for sse.start
    my @starts = grep { $_->{type} eq 'sse.start' } @{$result->{sent}};
    is(scalar @starts, 1, 'sse.start sent');
    is($starts[0]{status}, 200, 'status is 200');

    # Check for connected event
    my @events = get_sse_events($result);
    ok(@events >= 1, 'at least one SSE event sent');

    my ($connected) = grep { $_->{event} && $_->{event} eq 'connected' } @events;
    ok($connected, 'connected event received');
    is($connected->{data}, 'ok', 'connected event data is ok');
};

subtest 'SSE receives refresh on todo creation' => sub {
    PAGI::Simple::PubSub->reset;

    # First, set up an SSE subscriber manually to capture events
    use PAGI::Simple::SSE;

    my @sse_sent;
    my $sse = PAGI::Simple::SSE->new(
        app         => $app,
        scope       => { type => 'sse', path => '/todos/live' },
        receive     => sub { Future->done({ type => 'sse.disconnect' }) },
        send        => sub ($event) { push @sse_sent, $event; Future->done },
        path_params => {},
    );

    # Subscribe to the channel with a custom callback (mimics the real endpoint)
    $sse->subscribe('todos:changes' => sub ($msg) {
        $sse->send_event(event => 'refresh', data => $msg->{action} // 'update');
    });

    # Now create a todo which should trigger pubsub
    # Access service via service_registry (PerApp services are singletons)
    my $todos = $app->service_registry->{'Todo'};
    my $todo = $todos->new_todo;
    $todo->title('SSE Test Todo');
    $todos->save($todo);

    # Check if SSE received the refresh event
    my @refresh_events = grep {
        $_->{type} eq 'sse.send' &&
        $_->{event} && $_->{event} eq 'refresh'
    } @sse_sent;

    is(scalar @refresh_events, 1, 'refresh event received');
    is($refresh_events[0]{data}, 'save', 'refresh data is save action');

    # Clean up
    $sse->unsubscribe_all;
};

subtest 'SSE receives refresh on todo toggle' => sub {
    PAGI::Simple::PubSub->reset;

    use PAGI::Simple::SSE;

    my @sse_sent;
    my $sse = PAGI::Simple::SSE->new(
        app         => $app,
        scope       => { type => 'sse', path => '/todos/live' },
        receive     => sub { Future->done({ type => 'sse.disconnect' }) },
        send        => sub ($event) { push @sse_sent, $event; Future->done },
        path_params => {},
    );

    $sse->subscribe('todos:changes' => sub ($msg) {
        $sse->send_event(event => 'refresh', data => $msg->{action} // 'update');
    });

    # Get first todo and toggle it
    my $todos = $app->service_registry->{'Todo'};
    my @all = $todos->all;
    my $first = $all[0];
    $todos->toggle($first->id);

    # Check if SSE received the refresh event
    my @refresh_events = grep {
        $_->{type} eq 'sse.send' &&
        $_->{event} && $_->{event} eq 'refresh'
    } @sse_sent;

    is(scalar @refresh_events, 1, 'refresh event received on toggle');
    is($refresh_events[0]{data}, 'toggle', 'refresh data is toggle action');

    $sse->unsubscribe_all;
};

subtest 'SSE receives refresh on todo delete' => sub {
    PAGI::Simple::PubSub->reset;

    use PAGI::Simple::SSE;

    my @sse_sent;
    my $sse = PAGI::Simple::SSE->new(
        app         => $app,
        scope       => { type => 'sse', path => '/todos/live' },
        receive     => sub { Future->done({ type => 'sse.disconnect' }) },
        send        => sub ($event) { push @sse_sent, $event; Future->done },
        path_params => {},
    );

    $sse->subscribe('todos:changes' => sub ($msg) {
        $sse->send_event(event => 'refresh', data => $msg->{action} // 'update');
    });

    # Create a todo to delete
    my $todos = $app->service_registry->{'Todo'};
    my $todo = $todos->new_todo;
    $todo->title('To Be Deleted');
    $todos->save($todo);

    # Clear the save event
    @sse_sent = ();

    # Now delete it
    $todos->delete($todo->id);

    # Check if SSE received the refresh event
    my @refresh_events = grep {
        $_->{type} eq 'sse.send' &&
        $_->{event} && $_->{event} eq 'refresh'
    } @sse_sent;

    is(scalar @refresh_events, 1, 'refresh event received on delete');
    is($refresh_events[0]{data}, 'delete', 'refresh data is delete action');

    $sse->unsubscribe_all;
};

subtest 'Multiple SSE clients receive same events' => sub {
    PAGI::Simple::PubSub->reset;

    use PAGI::Simple::SSE;

    # Create two SSE clients
    my @sse1_sent;
    my $sse1 = PAGI::Simple::SSE->new(
        app         => $app,
        scope       => { type => 'sse', path => '/todos/live' },
        receive     => sub { Future->done({ type => 'sse.disconnect' }) },
        send        => sub ($event) { push @sse1_sent, $event; Future->done },
        path_params => {},
    );

    my @sse2_sent;
    my $sse2 = PAGI::Simple::SSE->new(
        app         => $app,
        scope       => { type => 'sse', path => '/todos/live' },
        receive     => sub { Future->done({ type => 'sse.disconnect' }) },
        send        => sub ($event) { push @sse2_sent, $event; Future->done },
        path_params => {},
    );

    # Both subscribe to the channel
    $sse1->subscribe('todos:changes' => sub ($msg) {
        $sse1->send_event(event => 'refresh', data => $msg->{action} // 'update');
    });

    $sse2->subscribe('todos:changes' => sub ($msg) {
        $sse2->send_event(event => 'refresh', data => $msg->{action} // 'update');
    });

    # Create a todo
    my $todos = $app->service_registry->{'Todo'};
    my $todo = $todos->new_todo;
    $todo->title('Multi-client Test');
    $todos->save($todo);

    # Both should receive the event
    my @sse1_refresh = grep {
        $_->{type} eq 'sse.send' && $_->{event} && $_->{event} eq 'refresh'
    } @sse1_sent;

    my @sse2_refresh = grep {
        $_->{type} eq 'sse.send' && $_->{event} && $_->{event} eq 'refresh'
    } @sse2_sent;

    is(scalar @sse1_refresh, 1, 'client 1 received refresh');
    is(scalar @sse2_refresh, 1, 'client 2 received refresh');

    $sse1->unsubscribe_all;
    $sse2->unsubscribe_all;
};

subtest 'SSE client unsubscription works' => sub {
    PAGI::Simple::PubSub->reset;

    use PAGI::Simple::SSE;

    my @sse_sent;
    my $sse = PAGI::Simple::SSE->new(
        app         => $app,
        scope       => { type => 'sse', path => '/todos/live' },
        receive     => sub { Future->done({ type => 'sse.disconnect' }) },
        send        => sub ($event) { push @sse_sent, $event; Future->done },
        path_params => {},
    );

    $sse->subscribe('todos:changes' => sub ($msg) {
        $sse->send_event(event => 'refresh', data => $msg->{action} // 'update');
    });

    # Unsubscribe
    $sse->unsubscribe_all;

    # Create a todo after unsubscription
    my $todos = $app->service_registry->{'Todo'};
    my $todo = $todos->new_todo;
    $todo->title('After Unsubscribe');
    $todos->save($todo);

    # Should NOT receive any events
    my @refresh_events = grep {
        $_->{type} eq 'sse.send' && $_->{event} && $_->{event} eq 'refresh'
    } @sse_sent;

    is(scalar @refresh_events, 0, 'no events after unsubscribe');
};

done_testing;
