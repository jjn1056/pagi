#!/usr/bin/env perl
use strict;
use warnings;
use experimental 'signatures';
use utf8;
use Future::AsyncAwait;

# PAGI::Simple Live Poll Example - Demonstrates htmx Integration
# Run with: pagi-server --app examples/simple-17-htmx-poll/app.pl --port 5000
#
# Features demonstrated:
# - htmx() script tag helper
# - hx_get(), hx_post(), hx_delete() attribute helpers
# - hx_sse() for real-time vote updates
# - Layout system with extends() and content_for()
# - Partial templates with include()

use PAGI::Simple;
use PAGI::Simple::PubSub;
use File::Basename qw(dirname);
use File::Spec;

# In-memory poll storage
my $next_id = 1;
my %polls = ();

# ============================================================================
# Helper functions (defined before use)
# ============================================================================

sub _create_poll ($question, $options) {
    my $id = $next_id++;
    $polls{$id} = {
        id       => $id,
        question => $question,
        options  => { map { $_ => 0 } @$options },
        created  => time(),
    };
    return $polls{$id};
}

sub _all_polls {
    return sort { $b->{created} <=> $a->{created} } values %polls;
}

sub _get_poll ($id) {
    return $polls{$id};
}

sub _vote ($id, $option) {
    my $poll = $polls{$id} or return;
    $poll->{options}{$option}++ if exists $poll->{options}{$option};
    return $poll;
}

sub _delete_poll ($id) {
    return delete $polls{$id};
}

# Seed with sample data
_create_poll('What is your favorite programming language?', ['Perl', 'Python', 'JavaScript', 'Rust']);
_create_poll('Best web framework approach?', ['Full-stack', 'Micro-framework', 'Static + API']);

# Find the share/htmx directory (relative to project root)
my $project_root = File::Spec->catdir(dirname(__FILE__), '..', '..');
my $htmx_dir = File::Spec->catdir($project_root, 'share', 'htmx');

my $app = PAGI::Simple->new(
    name  => 'Live Poll',
    views => 'templates',
);

# Serve htmx static files
$app->static('/static/htmx' => $htmx_dir);

# ============================================================================
# Routes
# ============================================================================

# Home page - list all polls
$app->get('/' => sub ($c) {
    $c->render('index',
        title => 'Live Polls',
        polls => [_all_polls()],
    );
})->name('home');

# Watch a poll with live SSE updates
$app->get('/polls/:id/watch' => sub ($c) {
    my $id = $c->path_params->{id};
    my $poll = _get_poll($id);

    unless ($poll) {
        return $c->status(404)->text('Poll not found');
    }

    $c->render('polls/watch',
        title => "Watch: $poll->{question}",
        poll  => $poll,
    );
})->name('watch_poll');

# Create a new poll
$app->post('/polls/create' => async sub ($c) {
    my $params = await $c->req->body_params;
    my $question = $params->{question} // '';
    my $options_str = $params->{options} // '';

    # Parse comma-separated options
    my @options = map { s/^\s+|\s+$//gr } split /,/, $options_str;
    @options = grep { length } @options;

    if ($question && @options >= 2) {
        my $poll = _create_poll($question, \@options);
        # Return just the new poll card
        $c->render('polls/_card', poll => $poll);
    } else {
        $c->status(400)->html('<div class="card"><p style="color:#dc2626">Need a question and at least 2 options</p></div>');
    }
});

# Vote on a poll option
$app->post('/polls/:id/vote' => async sub ($c) {
    my $id = $c->path_params->{id};
    my $poll = _get_poll($id);

    unless ($poll) {
        return $c->status(404)->text('Poll not found');
    }

    # Get the option from form data
    my $params = await $c->req->body_params;
    my $option = $params->{option};

    if ($option && exists $poll->{options}{$option}) {
        _vote($id, $option);

        # Broadcast vote update via SSE
        my $pubsub = PAGI::Simple::PubSub->instance;
        $pubsub->publish("poll:$id", "vote");
    }

    # Return updated poll card (htmx will swap it in)
    $c->render('polls/_card', poll => $poll);
});

# Delete a poll
$app->delete('/polls/:id' => sub ($c) {
    my $id = $c->path_params->{id};

    if (_delete_poll($id)) {
        # Return empty response - htmx will remove the element
        $c->html('');
    } else {
        $c->status(404)->text('Poll not found');
    }
});

# SSE endpoint for live poll updates
$app->sse('/polls/:id/live' => sub ($sse) {
    my $id = $sse->param('id');
    my $poll = _get_poll($id);

    return unless $poll;

    # Send initial connection event
    $sse->send_event(
        event => 'connected',
        data  => { poll_id => $id },
    );

    # Subscribe to this poll's channel with a callback for vote updates
    $sse->subscribe("poll:$id", sub ($msg) {
        my $poll = _get_poll($id);
        return unless $poll;

        # Render the updated poll card
        my $view = $sse->app->view;
        my $html = $view->render('polls/_card', poll => $poll, show_vote => 0);

        $sse->send_event(
            event => 'vote',
            data  => $html,
        );
    });
});

# Return the PAGI app (must be last expression in file)
$app->to_app;
