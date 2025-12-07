#!/usr/bin/env perl
use strict;
use warnings;
use experimental 'signatures';
use utf8;
use Future::AsyncAwait;

# PAGI::Simple Live Poll Example - Demonstrates htmx Integration + Service System
# Run with: pagi-server --app examples/simple-17-htmx-poll/app.pl --port 5000
#
# Features demonstrated:
# - Service system with $c->service('Poll')
# - PerApp service singleton (initialized at startup)
# - htmx() script tag helper
# - hx_get(), hx_post(), hx_delete() attribute helpers
# - hx_sse() for real-time vote updates
# - Layout system with extends() and content_for()
# - Partial templates with include()
#
# Step 4 Features (htmx request/response integration):
# - is_htmx() - detect htmx requests
# - Auto-fragment detection - layout auto-skipped for htmx requests
# - render_or_redirect() - render for htmx, redirect for browser
# - empty_or_redirect() - empty response for htmx delete, redirect for browser
# - hx_trigger() - trigger client-side events from server
# - layout => 0/1 - explicit layout control override

use PAGI::Simple;

my $app = PAGI::Simple->new(
    name   => 'Live Poll',
    views  => 'templates',
    share  => 'htmx',  # Mount PAGI's bundled htmx (required for htmx() helper)
    # namespace => 'LivePoll' is auto-generated from name
    # lib => './lib' is the default
);

# ============================================================================
# Routes
# ============================================================================

# Home page - list all polls
$app->get('/' => sub ($c) {
    my $polls = $c->service('Poll');

    $c->render('index',
        title => 'Live Polls',
        polls => [$polls->all],
    );
})->name('home');

# Watch a poll with live SSE updates
$app->get('/polls/:id/watch' => sub ($c) {
    my $id = $c->path_params->{id};
    my $polls = $c->service('Poll');
    my $poll = $polls->find($id);

    unless ($poll) {
        return $c->status(404)->text('Poll not found');
    }

    $c->render('polls/watch',
        title => "Watch: $poll->{question}",
        poll  => $poll,
    );
})->name('watch_poll');

# Get default options (for form reset)
$app->get('/polls/options/default' => sub ($c) {
    $c->render('polls/_options_fields', values => ['', '']);
});

# Add option field (htmx endpoint)
$app->post('/polls/options/add' => async sub ($c) {
    my $params = await $c->req->body_params;
    my @values = $params->get_all('options[]');

    # Add empty option (max 6)
    push @values, '' if @values != 6;

    $c->render('polls/_options_fields', values => \@values);
});

# Remove option field (htmx endpoint)
$app->post('/polls/options/remove' => async sub ($c) {
    my $params = await $c->req->body_params;
    my @values = $params->get_all('options[]');
    my $remove_index = $params->{remove_index} // -1;

    # Remove the specified index (min 2 options)
    if (@values != 2 && $remove_index >= 0 && $remove_index != @values) {
        splice(@values, $remove_index, 1);
    }

    $c->render('polls/_options_fields', values => \@values);
});

# Create a new poll
# Demonstrates: render_or_redirect() and hx_trigger()
$app->post('/polls/create' => async sub ($c) {
    my $params = await $c->req->body_params;
    my $question = $params->{question} // '';

    # Get options from array-style params (get_all returns list, not arrayref)
    my @raw_options = $params->get_all('options[]');

    # Filter empty values and trim whitespace
    my @options = grep { length } map { s/^\s+|\s+$//gr } @raw_options;

    if ($question && @options >= 2 && @options <= 6) {
        my $polls = $c->service('Poll');
        my $poll = $polls->create($question, \@options);

        # Trigger client-side event (htmx will listen for this)
        $c->hx_trigger('pollCreated', poll_id => $poll->{id});

        # render_or_redirect():
        # - htmx request: renders 'polls/_card' partial (layout auto-skipped)
        # - browser request: redirects to home page
        await $c->render_or_redirect('/', 'polls/_card', poll => $poll);
    } else {
        $c->status(400)->html('<div class="card"><p style="color:#dc2626">Need a question and 2-6 options</p></div>');
    }
});

# Vote on a poll option
# Demonstrates: hx_trigger() to notify other components
$app->post('/polls/:id/vote' => async sub ($c) {
    my $id = $c->path_params->{id};
    my $polls = $c->service('Poll');
    my $poll = $polls->find($id);

    unless ($poll) {
        return $c->status(404)->text('Poll not found');
    }

    # Get the option from form data
    my $params = await $c->req->body_params;
    my $option = $params->{option};

    if ($option && exists $poll->{options}{$option}) {
        $polls->vote($id, $option);

        # Broadcast vote update via SSE (for live watchers)
        $app->pubsub->publish($polls->channel_name($id), "vote");

        # Trigger client-side event with vote data
        $c->hx_trigger('voteRecorded', poll_id => $id, option => $option);
    }

    # Return updated poll card (layout auto-skipped for htmx requests)
    await $c->render('polls/_card', poll => $poll);
});

# Delete a poll
# Demonstrates: empty_or_redirect() and hx_trigger()
$app->delete('/polls/:id' => async sub ($c) {
    my $id = $c->path_params->{id};
    my $polls = $c->service('Poll');

    if ($polls->delete($id)) {
        # Notify any watchers that the poll was deleted
        $app->pubsub->publish($polls->channel_name($id), { action => 'deleted' });

        # Trigger client-side event for any listeners
        $c->hx_trigger('pollDeleted', poll_id => $id);

        # empty_or_redirect():
        # - htmx request: returns empty 200 (element gets swapped out)
        # - browser request: redirects to home page
        await $c->empty_or_redirect('/');
    } else {
        $c->status(404)->text('Poll not found');
    }
});

# SSE endpoint for live poll updates
$app->sse('/polls/:id/live' => sub ($sse) {
    my $id = $sse->param('id');

    # Get the Poll service from app's registry (PerApp services are singletons)
    my $poll_service = $sse->app->service_registry->{Poll};
    my $poll = $poll_service->find($id);

    return unless $poll;

    # Send initial connection event
    $sse->send_event(
        event => 'connected',
        data  => { poll_id => $id },
    );

    # Subscribe to this poll's channel with a callback for updates
    $sse->subscribe($poll_service->channel_name($id), sub ($msg) {
        my $view = $sse->app->view;

        # Check if this is a deletion notification
        if (ref $msg eq 'HASH' && $msg->{action} eq 'deleted') {
            my $html = $view->render('polls/_deleted');
            $sse->send_event(
                event => 'deleted',
                data  => $html,
            );
            return;
        }

        # Otherwise it's a vote update - get fresh poll data
        my $poll = $poll_service->find($id);
        return unless $poll;

        my $html = $view->render('polls/_card', poll => $poll, show_vote => 0, show_delete => 0, show_watch => 0);
        $sse->send_event(
            event => 'vote',
            data  => $html,
        );
    });
});

# Return the PAGI app (must be last expression in file)
$app->to_app;
