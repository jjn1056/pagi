package ChatApp::SSE;

use strict;
use warnings;

use Future::AsyncAwait;
use JSON::MaybeXS;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Scalar::Util qw(weaken);

use ChatApp::State qw(
    add_sse_subscriber remove_sse_subscriber get_sse_subscribers
    get_recent_system_events get_stats generate_id
);

my $JSON = JSON::MaybeXS->new->utf8->canonical;

sub handler {
    return async sub  {
        my ($scope, $receive, $send) = @_;
        # Extract Last-Event-ID from headers if provided
        my $last_event_id = 0;
        for my $header (@{$scope->{headers} // []}) {
            if (lc($header->[0]) eq 'last-event-id') {
                $last_event_id = int($header->[1] // 0);
                last;
            }
        }

        # Send SSE headers
        await $send->({
            type    => 'sse.start',
            status  => 200,
            headers => [
                ['cache-control', 'no-cache'],
                ['x-accel-buffering', 'no'], # Disable nginx buffering
            ],
        });

        # Generate subscriber ID
        my $sub_id = generate_id();

        # Register subscriber with our send callback
        add_sse_subscriber($sub_id, $send, $last_event_id);

        # Send catch-up events
        my $missed_events = get_recent_system_events($last_event_id);
        for my $event (@$missed_events) {
            await _send_sse_event($send, $event);
        }

        # Send initial stats
        await _send_stats($send);

        # Set up periodic stats timer using IO::Async
        my $loop = IO::Async::Loop->new;
        my $connected = 1;

        # Weak reference for timer callback
        my $weak_send = $send;
        weaken($weak_send);

        my $timer = IO::Async::Timer::Periodic->new(
            interval => 10,  # Send stats every 10 seconds
            on_tick  => sub {
                return unless $connected && $weak_send;
                eval {
                    # Fire and forget - send stats asynchronously
                    _send_stats_sync($weak_send);
                };
            },
        );

        $loop->add($timer);
        $timer->start;

        # Wait for disconnect
        eval {
            while (1) {
                my $event = await $receive->();

                if ($event->{type} eq 'sse.disconnect') {
                    last;
                }
            }
        };

        # Cleanup
        $connected = 0;
        $timer->stop;
        $loop->remove($timer);
        remove_sse_subscriber($sub_id);
    };
}

# Synchronous version for timer callback (returns Future, doesn't await)
sub _send_stats_sync {
    my ($send) = @_;

    my $stats = get_stats();

    $send->({
        type  => 'sse.send',
        event => 'stats',
        data  => $JSON->encode($stats),
    });
}

# Background broadcaster - call this when system events occur
sub broadcast_event {
    my ($event) = @_;

    my $subscribers = get_sse_subscribers();

    for my $sub_id (keys %$subscribers) {
        my $sub = $subscribers->{$sub_id};
        next unless $sub && $sub->{send_cb};

        eval {
            $sub->{send_cb}->({
                type  => 'sse.send',
                event => $event->{type},
                data  => $JSON->encode($event->{data}),
                id    => $event->{id},
            });
        };

        if ($@) {
            # Remove dead subscriber
            remove_sse_subscriber($sub_id);
        }
    }
}

async sub _send_sse_event {
    my ($send, $event) = @_;

    my $event_type = $event->{type};
    my $data = $JSON->encode($event->{data});
    my $id = $event->{id};

    await $send->({
        type  => 'sse.send',
        event => $event_type,
        data  => $data,
        id    => $id,
    });
}

async sub _send_stats {
    my ($send) = @_;

    my $stats = get_stats();

    await $send->({
        type  => 'sse.send',
        event => 'stats',
        data  => $JSON->encode($stats),
    });
}

1;

__END__

# NAME

ChatApp::SSE - Server-Sent Events handler for system notifications

# DESCRIPTION

Handles SSE connections for real-time system-wide event broadcasting.

## Event Types

- **user_connected** - A user has connected to the chat.
- **user_disconnected** - A user has disconnected from the chat.
- **room_created** - A new room has been created.
- **room_deleted** - An empty room has been deleted.
- **stats** - Server statistics (sent every 10 seconds).

## Catch-Up Support

Clients can send the `Last-Event-ID` header to receive missed events
since the specified ID.
