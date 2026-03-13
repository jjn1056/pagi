package PAGI::Test::SSE;

use strict;
use warnings;
use Future::AsyncAwait;
use Future;
use Carp qw(croak);


sub new {
    my ($class, %args) = @_;

    croak "app is required" unless $args{app};
    croak "scope is required" unless $args{scope};

    return bless {
        app        => $args{app},
        scope      => $args{scope},
        recv_queue => [],      # Events from app -> test
        closed     => 0,
        started    => 0,
    }, $class;
}

sub _start {
    my ($self) = @_;

    # Create receive coderef for the app (always returns disconnect when closed)
    my $receive = async sub {
        if ($self->{closed}) {
            return { type => 'sse.disconnect' };
        }

        # SSE only receives disconnects from client, so we wait indefinitely
        # until the connection is closed
        my $future = Future->new;
        # This future will be resolved when close() is called
        push @{$self->{_pending_receives} //= []}, $future;
        return await $future;
    };

    # Create send coderef for the app
    my $send = async sub {
        my ($event) = @_;

        if ($event->{type} eq 'sse.start') {
            $self->{started} = 1;
            $self->{status} = $event->{status} // 200;
            $self->{headers} = $event->{headers} // [];
        }
        elsif ($event->{type} eq 'sse.send') {
            push @{$self->{recv_queue}}, $event;
        }

        return;
    };

    # Start the app future but don't block on it
    $self->{app_future} = $self->{app}->($self->{scope}, $receive, $send);

    # Wait for sse.start (this should complete immediately)
    # We need to let the app run until it starts
    $self->_pump_app;

    croak "SSE connection not started" unless $self->{started};

    return $self;
}

sub _pump_app {
    my ($self) = @_;

    # If closed and there are pending receives, resolve them with disconnect
    if ($self->{closed} && $self->{_pending_receives}) {
        while (my $future = shift @{$self->{_pending_receives}}) {
            $future->done({ type => 'sse.disconnect' }) unless $future->is_ready;
        }
    }
}

sub receive_event {
    my ($self, %opts) = @_;
    my $timeout = $opts{timeout} // 5;

    # Check if we have an event already waiting
    if (@{$self->{recv_queue}}) {
        my $event = shift @{$self->{recv_queue}};

        # Extract SSE event fields
        return {
            event => $event->{event},
            data  => $event->{data},
            id    => $event->{id},
            retry => $event->{retry},
        };
    }

    # Check if connection closed
    return undef if $self->{closed};

    # No event available yet
    croak "Timeout waiting for SSE event";
}

sub receive_json {
    my ($self, %opts) = @_;

    my $event = $self->receive_event(%opts);
    return undef unless defined $event;

    require JSON::MaybeXS;
    return JSON::MaybeXS::decode_json($event->{data});
}

sub close {
    my ($self) = @_;

    return if $self->{closed};

    $self->{closed} = 1;

    # Pump the app to let it process the disconnect
    $self->_pump_app;

    return $self;
}

sub is_closed {
    my ($self) = @_;
    return $self->{closed};
}

1;

__END__

=head1 NAME

PAGI::Test::SSE - Server-Sent Events connection for testing PAGI applications

=head1 SYNOPSIS

    use PAGI::Test::Client;

    my $client = PAGI::Test::Client->new(app => $sse_app);

    # Callback style (auto-close)
    $client->sse('/events', sub {
        my ($sse) = @_;
        my $event = $sse->receive_event;
        is $event->{event}, 'connected';
        is $event->{data}, '{"subscriber_id":1}';
    });

    # Explicit style
    my $sse = $client->sse('/events');
    my $event = $sse->receive_event;
    is $event->{event}, 'update';
    $sse->close;

    # JSON convenience
    my $sse = $client->sse('/events');
    my $data = $sse->receive_json;
    is $data->{subscriber_id}, 1;
    $sse->close;

=head1 DESCRIPTION

PAGI::Test::SSE provides a test client for Server-Sent Events (SSE) connections
in PAGI applications. It handles the SSE protocol handshake and event reception,
making it easy to test SSE endpoints without starting a real server.

This module is typically used via L<PAGI::Test::Client>'s C<sse> method rather
than directly.

SSE is a unidirectional protocol where the server sends events to the client.
Unlike WebSocket, the client cannot send messages back (except for disconnect).

B<This module is a simplified in-process model of an SSE connection.> It is
well-suited to application-level event testing, but it does B<not> emulate
transport timing, buffering, or wire-format behavior.

=head1 CONSTRUCTOR

=head2 new

    my $sse = PAGI::Test::SSE->new(
        app   => $app,     # Required: PAGI app coderef
        scope => $scope,   # Required: SSE scope hashref
    );

Creates a new SSE test connection. Typically you don't call this directly;
use L<PAGI::Test::Client>'s C<sse> method instead.

=head1 METHODS

=head2 receive_event

    my $event = $sse->receive_event;
    my $event = $sse->receive_event(timeout => 10);

Waits for and returns the next event from the server. Returns a hashref with
the following fields:

=over 4

=item event

The event type (optional). If not specified in the server message, this will
be undef.

=item data

The event data (required). This is the raw string data sent by the server.

=item id

The event ID (optional). Can be used for reconnection logic.

=item retry

The retry time in milliseconds (optional). Indicates how long the client should
wait before reconnecting.

=back

Returns undef if the connection is closed. Throws an exception if timeout is
reached.

B<Current limitation:> this method does not actually block or wait for the
timeout duration. If no queued SSE event is immediately available, it throws
an exception right away.

Example:

    my $event = $sse->receive_event;
    if ($event->{event} eq 'update') {
        say "Received update: $event->{data}";
    }

=head2 receive_json

    my $data = $sse->receive_json;
    my $data = $sse->receive_json(timeout => 10);

Waits for an event, extracts the data field, decodes it as JSON, and returns
the resulting Perl data structure. Dies if the data is not valid JSON.

This is a convenience method equivalent to:

    my $event = $sse->receive_event;
    my $data = decode_json($event->{data});

=head1 LIMITATIONS

=over 4

=item *

This helper does not simulate real SSE wire formatting, chunking, buffering,
or transport timing.

=item *

The receive timeout arguments are advisory only at present; receive methods
check the current queue immediately rather than waiting asynchronously.

=item *

For keepalive behavior, disconnect timing, or full transport-level testing,
test against L<PAGI::Server>.

=back

Example:

    my $data = $sse->receive_json;
    is $data->{subscriber_id}, 1;

=head2 close

    $sse->close;

Closes the SSE connection. This sends a C<sse.disconnect> event to the
application, allowing it to clean up resources.

=head2 is_closed

    if ($sse->is_closed) {
        say "Connection closed";
    }

Returns true if the SSE connection has been closed.

=head1 INTERNAL METHODS

=head2 _start

    $sse->_start;

Internal method called by L<PAGI::Test::Client> to start the SSE connection,
send the initial scope to the app, and wait for the C<sse.start> event.

=head1 SSE PROTOCOL

This module implements the PAGI SSE protocol:

=over 4

=item 1. App sends C<sse.start> event with status and headers

=item 2. App sends C<sse.send> events with event/data/id/retry fields

=item 3. Test sends C<sse.disconnect> event when connection is closed

=back

=head1 EXAMPLE

    use Test2::V0;
    use PAGI::Test::Client;
    use Future::AsyncAwait;

    # Simple SSE app that sends a few events
    my $sse_app = async sub {
        my ($scope, $receive, $send) = @_;
        die "Expected sse scope" unless $scope->{type} eq 'sse';

        await $send->({
            type    => 'sse.start',
            status  => 200,
            headers => [],
        });

        await $send->({
            type  => 'sse.send',
            event => 'connected',
            data  => '{"subscriber_id":1}',
        });

        await $send->({
            type  => 'sse.send',
            event => 'update',
            data  => '{"count":42}',
            id    => 'msg-1',
        });
    };

    # Test it
    my $client = PAGI::Test::Client->new(app => $sse_app);
    $client->sse('/events', sub {
        my ($sse) = @_;

        my $event1 = $sse->receive_event;
        is $event1->{event}, 'connected', 'first event type';

        my $event2 = $sse->receive_event;
        is $event2->{event}, 'update', 'second event type';
        is $event2->{id}, 'msg-1', 'event id';
    });

=head1 SEE ALSO

L<PAGI::Test::Client>, L<PAGI::Test::Response>, L<PAGI::Test::WebSocket>

=head1 AUTHOR

PAGI Contributors

=cut
