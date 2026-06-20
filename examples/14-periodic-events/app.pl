use strict;
use warnings;
use Future::AsyncAwait;
use Future::IO;
use Future::Selector;
use JSON::PP ();

# A periodic background event source, rooted in the lifespan scope, plus the
# rendezvous that lets request handlers (/next, /stream) wait for its ticks.
#
# An event-driven app is a TREE of futures. Long-lived background work belongs
# on a branch of that tree -- here, a Future::Selector held in the lifespan
# handler's frame, which the server keeps alive for the whole life of the app.
# Nothing is held in a file-scoped variable, so nothing is silently dropped, and
# because the selector propagates failures, a crashing source surfaces (the
# server logs it) instead of vanishing.
#
# Anti-pattern, for contrast: starting the source at file scope and pinning it in
# an `our` (or a bare `my`, which is worse -- it is garbage-collected the moment
# the app file finishes loading and dies with a cryptic "lost its returning
# future" warning). That is a future with no parent in the tree. Give it a parent
# instead: the lifespan scope.

# The rendezvous: a tiny event hub the source publishes to and requests wait on.
#
# This is the RIGHT shape for sharing mutable data through $scope->{state}. Each
# request scope receives a *shallow copy* of the lifespan state: the top-level
# keys are private to that scope, but the values (object references) are shared.
# So we store ONE hub object in the lifespan and let every request reach it
# through that shared reference -- nobody ever *replaces* a top-level state key
# (which would only change one scope's copy and silently desync the rest). The
# hub owns its waiter list and only ever mutates it in place.
package TickHub {
    sub new { bless { count => 0, beats => 0, waiters => [] }, shift }

    sub count { $_[0]{count} }
    sub beats { $_[0]{beats} }

    # Subscribe to the next tick: returns a Future that resolves with the new
    # tick count. Non-blocking -- the caller awaits it while others are served.
    sub next_tick {
        my ($self) = @_;
        my $f = Future->new;
        push @{ $self->{waiters} }, $f;
        return $f;
    }

    # Publish a tick: advance the counter and wake everyone waiting. We splice
    # the waiter list (emptying it IN PLACE -- never reassigning the slot) and
    # iterate the drained copy, so a subscriber that re-subscribes synchronously
    # when its Future resolves cannot grow the list we are walking.
    sub publish {
        my ($self) = @_;
        $self->{count}++;
        my @waiters = splice @{ $self->{waiters} };
        $_->done($self->{count}) for @waiters;
        return;
    }

    # A second, slower source -- it has no subscribers, it just advances a counter.
    sub beat { $_[0]{beats}++; return; }
}

async sub handle_lifespan {
    my ($scope, $receive, $send) = @_;

    # Store the hub ONCE. Every request scope sees this same object through the
    # shallow copy of state (see TickHub above).
    my $state = $scope->{state} //= {};
    my $hub   = $state->{ticks} = TickHub->new;

    # Wait for startup, then announce we are ready.
    while (1) {
        my $event = await $receive->();
        last if $event->{type} eq 'lifespan.startup';
    }
    await $send->({ type => 'lifespan.startup.complete' });

    # Two independent background sources on ONE Future::Selector. The ticker
    # publishes to the hub every $INTERVAL seconds (waking /next and /stream); the
    # heartbeat just advances a counter every $HEARTBEAT seconds. Future::IO->sleep
    # names no event loop -- it runs on whatever loop the server uses. The selector
    # multiplexes both, holds their futures (so nothing needs an `our`), and if
    # either source fails, $selector->run fails and the error surfaces.
    my $INTERVAL  = 2;
    my $HEARTBEAT = 5;
    my $selector  = Future::Selector->new;
    $selector->add(
        data => 'ticker',
        gen  => async sub {
            await Future::IO->sleep($INTERVAL);
            $hub->publish;
            return;
        },
    );
    $selector->add(
        data => 'heartbeat',
        gen  => async sub {
            await Future::IO->sleep($HEARTBEAT);
            $hub->beat;
            return;
        },
    );

    # Run the source until shutdown. wait_any resolves when shutdown arrives
    # (cancelling the selector); if a source fails, wait_any fails and the error
    # propagates out of this handler for the server to log.
    my $shutdown = (async sub {
        while (1) {
            my $event = await $receive->();
            return if $event->{type} eq 'lifespan.shutdown';
        }
    })->();
    await Future->wait_any($shutdown, $selector->run);

    await $send->({ type => 'lifespan.shutdown.complete' });
}

# Resolve as soon as ANY of the given futures is ready, leaving them all intact.
# (Future->wait_any cancels the losers; here we must not cancel the long-lived
# $receive future, so we just watch each with on_ready.)
async sub await_either {
    my @futures = @_;
    my $first = Future->new;
    $_->on_ready(sub { $first->done unless $first->is_ready }) for @futures;
    await $first;
    return;
}

async sub handle_http {
    my ($scope, $receive, $send) = @_;

    my $hub = $scope->{state}{ticks};

    # Drain the request body.
    while (1) {
        my $event = await $receive->();
        last if $event->{type} ne 'http.request';
        last unless $event->{more};
    }

    if (($scope->{path} // '/') eq '/stream') {
        # A long-running stream driven by events OUTSIDE this handler: each tick
        # the background source publishes, this loop relays it -- one NDJSON line
        # per tick -- until the client disconnects. The handler produces nothing
        # of its own.
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [ ['content-type', 'application/x-ndjson'] ],
        });

        # The in-handler multiplex (the "level 2" idiom): await the next tick OR a
        # client disconnect, whichever comes first, so a disconnect stops the
        # stream promptly. We race with await_either rather than Future->wait_any,
        # which would cancel the disconnect future and end $receive.
        my $disconnect = $receive->();
        while (1) {
            my $tick_f = $hub->next_tick;
            await await_either($disconnect, $tick_f);
            last if $disconnect->is_ready;      # client gone -- stop the stream
            my $tick = $tick_f->get;
            await $send->({
                type => 'http.response.body',
                body => qq({"tick":$tick}\n),
                more => 1,
            });
        }
        return;
    }

    if (($scope->{path} // '/') eq '/next') {
        # "Listen" for the next tick. Non-blocking -- other requests are served
        # while this one waits.
        await reply($send, 200, { tick => await $hub->next_tick });
    }
    else {
        await reply($send, 200,
            { count => $hub->count, beats => $hub->beats,
              hint => 'GET /next to wait for the next tick' });
    }
}

async sub reply {
    my ($send, $status, $data) = @_;
    await $send->({
        type    => 'http.response.start',
        status  => $status,
        headers => [ ['content-type', 'application/json'] ],
    });
    await $send->({
        type => 'http.response.body',
        body => JSON::PP::encode_json($data),
        more => 0,
    });
}

my $app = async sub {
    my ($scope, $receive, $send) = @_;

    return await handle_lifespan($scope, $receive, $send) if $scope->{type} eq 'lifespan';
    return await handle_http($scope, $receive, $send)     if $scope->{type} eq 'http';

    # Decline any other scope by raising -- the canonical PAGI idiom.
    die "Unsupported scope type: $scope->{type}";
};

$app;
