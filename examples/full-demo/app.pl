#!/usr/bin/env perl
use strict;
use warnings;
use Future::AsyncAwait;
use PAGI::App::Router;
use PAGI::Utils qw(handle_lifespan);

# Safe sleep that works even without Future::IO backend
my $HAS_FUTURE_IO = eval { require Future::IO; 1 };
sub maybe_sleep {
    my ($seconds) = @_;
    return $HAS_FUTURE_IO ? Future::IO->sleep($seconds) : Future->done;
}

# Watch for SSE disconnect in background
async sub watch_sse_disconnect {
    my ($receive) = @_;
    while (1) {
        my $event = await $receive->();
        return $event if $event->{type} eq 'sse.disconnect';
    }
}

# Create the router
my $router = PAGI::App::Router->new;

# ============================================================================
# HTTP Routes
# ============================================================================

# Hello World endpoint
$router->get('/' => async sub {
    my ($scope, $receive, $send) = @_;

    await $send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [['content-type', 'text/plain']],
    });
    await $send->({
        type => 'http.response.body',
        body => 'Hello, World!',
        more => 0,
    });
})->name('hello');

# POST Echo - echoes back the request body
$router->post('/echo' => async sub {
    my ($scope, $receive, $send) = @_;

    # Find content-type from request headers (array of pairs)
    my $content_type = 'application/octet-stream';
    for my $header (@{$scope->{headers} // []}) {
        if (lc($header->[0]) eq 'content-type') {
            $content_type = $header->[1];
            last;
        }
    }

    # Collect the request body
    my $body = '';
    while (1) {
        my $event = await $receive->();
        last if $event->{type} ne 'http.request';
        $body .= $event->{body} // '';
        last unless $event->{more};
    }

    await $send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [
            ['content-type', $content_type],
            ['x-echoed-length', length($body)],
        ],
    });
    await $send->({
        type => 'http.response.body',
        body => $body,
        more => 0,
    });
})->name('echo');

# HTTP Streaming - sends chunks with delays
$router->get('/stream' => async sub {
    my ($scope, $receive, $send) = @_;

    # Access shared state from lifespan
    my $counter = $scope->{state}{request_counter}++;

    await $send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [['content-type', 'text/plain']],
    });

    my @chunks = (
        "Stream started (request #$counter)\n",
        "Chunk 1: Processing...\n",
        "Chunk 2: Working...\n",
        "Chunk 3: Almost done...\n",
        "Stream complete!\n",
    );

    for my $i (0 .. $#chunks) {
        my $more = ($i < $#chunks) ? 1 : 0;
        await $send->({
            type => 'http.response.body',
            body => $chunks[$i],
            more => $more,
        });
        await maybe_sleep(0.5) if $more;
    }
})->name('http_stream');

# ============================================================================
# WebSocket Route
# ============================================================================

$router->websocket('/ws/echo' => async sub {
    my ($scope, $receive, $send) = @_;

    # Wait for connect event
    my $event = await $receive->();
    return unless $event->{type} eq 'websocket.connect';

    # Accept the connection
    await $send->({ type => 'websocket.accept' });

    # Echo loop
    while (1) {
        my $frame = await $receive->();

        if ($frame->{type} eq 'websocket.receive') {
            if (defined $frame->{text}) {
                await $send->({
                    type => 'websocket.send',
                    text => "Echo: $frame->{text}",
                });
            }
            elsif (defined $frame->{bytes}) {
                await $send->({
                    type  => 'websocket.send',
                    bytes => $frame->{bytes},
                });
            }
        }
        elsif ($frame->{type} eq 'websocket.disconnect') {
            last;
        }
    }
})->name('ws_echo');

# ============================================================================
# SSE Route
# ============================================================================

$router->sse('/events' => async sub {
    my ($scope, $receive, $send) = @_;

    # Start SSE stream
    await $send->({
        type    => 'sse.start',
        status  => 200,
        headers => [['content-type', 'text/event-stream']],
    });

    # Watch for disconnect in background
    my $disconnect = watch_sse_disconnect($receive);

    # Send events
    my $count = 0;
    while ($count < 10) {
        last if $disconnect->is_ready;

        $count++;
        await $send->({
            type  => 'sse.send',
            event => 'tick',
            id    => $count,
            data  => "Event #$count at " . time(),
        });

        await maybe_sleep(1);
    }

    # Final event
    unless ($disconnect->is_ready) {
        await $send->({
            type  => 'sse.send',
            event => 'done',
            data  => 'Stream complete',
        });
    }

    $disconnect->cancel if $disconnect->can('cancel') && !$disconnect->is_ready;
})->name('sse_events');

# ============================================================================
# Main Application with Lifespan
# ============================================================================

async sub pagi {
    my ($scope, $receive, $send) = @_;

    # Handle lifespan events
    return await handle_lifespan(
        $scope, $receive, $send,
        startup => async sub {
            my ($state) = @_;
            warn "[STARTUP] Initializing application...\n";

            # Initialize shared state
            $state->{request_counter} = 0;
            $state->{started_at} = time();

            # Initialize resources here (DB connections, caches, etc.)
            warn "[STARTUP] Application ready!\n";
        },
        shutdown => async sub {
            my ($state) = @_;
            my $uptime = time() - ($state->{started_at} // time());
            my $requests = $state->{request_counter} // 0;
            warn "[SHUTDOWN] Shutting down after ${uptime}s, handled $requests requests\n";

            # Cleanup resources here
            warn "[SHUTDOWN] Cleanup complete\n";
        },
    ) if $scope->{type} eq 'lifespan';

    # Route all other requests through the router
    return await $router->to_app->($scope, $receive, $send);
}

\&pagi;
