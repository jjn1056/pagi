use strict;
use warnings;
use Future::AsyncAwait;
use Future::IO;
use Future::Selector;
use JSON::PP ();

# A periodic background event source, rooted in the lifespan scope.
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

async sub handle_lifespan {
    my ($scope, $receive, $send) = @_;

    # Shared state, visible to every request scope via $scope->{state}.
    my $state = $scope->{state} //= {};
    $state->{count}   = 0;
    $state->{waiters} = [];

    # Wait for startup, then announce we are ready.
    while (1) {
        my $event = await $receive->();
        last if $event->{type} eq 'lifespan.startup';
    }
    await $send->({ type => 'lifespan.startup.complete' });

    # The event source: every $INTERVAL seconds produce a tick and deliver it to
    # anyone currently listening on /next. The Future::IO->sleep names no event
    # loop -- it runs on whatever loop the server uses. The selector holds the
    # source's futures, so it is retained without any `our`.
    my $INTERVAL = 2;
    my $selector = Future::Selector->new;
    $selector->add(
        data => 'ticker',
        gen  => async sub {
            await Future::IO->sleep($INTERVAL);
            $state->{count}++;
            my $waiters = $state->{waiters};
            $state->{waiters} = [];
            $_->done($state->{count}) for @$waiters;
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

async sub handle_http {
    my ($scope, $receive, $send) = @_;

    my $state = $scope->{state} // {};

    # Drain the request body.
    while (1) {
        my $event = await $receive->();
        last if $event->{type} ne 'http.request';
        last unless $event->{more};
    }

    if (($scope->{path} // '/') eq '/next') {
        # "Listen" for the next tick: register a Future the source resolves.
        # Non-blocking -- other requests are served while this one waits.
        my $f = Future->new;
        push @{ $state->{waiters} }, $f;
        await reply($send, 200, { tick => await $f });
    }
    else {
        await reply($send, 200,
            { count => $state->{count} // 0, hint => 'GET /next to wait for the next tick' });
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
