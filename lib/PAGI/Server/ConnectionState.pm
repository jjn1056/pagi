package PAGI::Server::ConnectionState;

use strict;
use warnings;
use Scalar::Util qw(weaken);

=head1 NAME

PAGI::Server::ConnectionState - Connection state tracking for HTTP requests

=head1 SYNOPSIS

    my $conn = $scope->{'pagi.connection'};

    # Synchronous, non-destructive check
    if ($conn->is_connected) {
        # Client still connected
    }

    # Get disconnect reason (undef while connected)
    my $reason = $conn->disconnect_reason;

    # Register cleanup callback
    $conn->on_disconnect(sub {
        my ($reason) = @_;
        cleanup_resources();
    });

    # Await disconnect (if Future provided)
    if (my $future = $conn->disconnect_future) {
        my $reason = await $future;
    }

=head1 DESCRIPTION

PAGI::Server::ConnectionState provides a mechanism for applications to detect
client disconnection without consuming messages from the receive queue.

This addresses a fundamental limitation in the PAGI (and ASGI) model where
checking for disconnect via C<receive()> may inadvertently consume request
body data.

The C<disconnect_future()> method lazily creates a Future only when called,
avoiding allocation overhead for simple request/response handlers that don't
need async disconnect detection.

See the "Connection State" section in L<docs/specs/www.mkdn> for the
full specification.

=head1 METHODS

=head2 new

    my $conn = PAGI::Server::ConnectionState->new(connection => $connection);

Creates a new connection state object. The C<connection> argument provides
a reference to the parent Connection object for lazy Future creation.

=cut

sub new {
    my ($class, %args) = @_;

    my $connected = 1;
    my $reason = undef;

    my $self = bless {
        # Connection reference for lazy Future creation (will be weakened)
        _connection => $args{connection},

        # State (scalar refs - for internal consistency)
        _connected => \$connected,
        _reason    => \$reason,

        # Lazy Future (only created if disconnect_future() called)
        _future => undef,

        # Callbacks registered via on_disconnect()
        _callbacks => [],
    }, $class;

    # Weaken to avoid circular reference: Connection -> ConnectionState -> Connection
    weaken($self->{_connection}) if $self->{_connection};

    return $self;
}

=head2 is_connected

    my $connected = $conn->is_connected;  # Boolean

Returns true if the connection is still open, false if disconnected.

This is a synchronous, non-destructive check that does not consume
messages from the receive queue.

=cut

sub is_connected {
    my $self = shift;
    return ${$self->{_connected}} ? 1 : 0;
}

=head2 disconnect_reason

    my $reason = $conn->disconnect_reason;  # String or undef

Returns the disconnect reason string, or C<undef> if still connected.

Standard reason strings:

=over 4

=item * C<client_closed> - Client initiated clean close (TCP FIN)

=item * C<client_timeout> - Client stopped responding (read timeout)

=item * C<idle_timeout> - Connection idle too long between requests

=item * C<write_timeout> - Response write timed out

=item * C<write_error> - Socket write failed (EPIPE, ECONNRESET)

=item * C<read_error> - Socket read failed

=item * C<protocol_error> - HTTP parse error, invalid request

=item * C<server_shutdown> - Server shutting down gracefully

=item * C<body_too_large> - Request body exceeded limit

=back

=cut

sub disconnect_reason {
    my $self = shift;
    return ${$self->{_reason}};
}

=head2 disconnect_future

    my $future = $conn->disconnect_future;  # Future or undef
    my $reason = await $future;

Returns a Future that resolves when the connection closes.

The Future is created lazily on first call, avoiding allocation overhead
for handlers that don't need async disconnect detection.

The Future resolves with the disconnect reason string.

This is useful for racing against other async operations:

    await Future->wait_any($disconnect_future, $event_future);

=cut

sub disconnect_future {
    my $self = shift;

    # Return cached Future if exists
    return $self->{_future} if $self->{_future};

    # Create new Future (lazy)
    my $conn = $self->{_connection};
    my $loop = $conn && $conn->{server} ? $conn->{server}->loop : undef;

    if ($loop) {
        $self->{_future} = $loop->new_future;
    } else {
        # Fallback if no loop available (shouldn't happen in practice)
        require Future;
        $self->{_future} = Future->new;
    }

    # If already disconnected, resolve immediately
    unless (${$self->{_connected}}) {
        $self->{_future}->done(${$self->{_reason}});
    }

    return $self->{_future};
}

=head2 on_disconnect

    $conn->on_disconnect(sub {
        my ($reason) = @_;
        # cleanup code
    });

Registers a callback to be invoked when disconnect occurs.

=over 4

=item * May be called multiple times to register multiple callbacks

=item * Callbacks are invoked in registration order

=item * Callbacks receive the disconnect reason as the first argument

=item * If registered after disconnect already occurred, callback is
invoked immediately with the reason

=item * One callback's failure does not prevent other callbacks from
being invoked

=back

=cut

sub on_disconnect {
    my ($self, $cb) = @_;

    # If already disconnected, invoke immediately
    unless (${$self->{_connected}}) {
        eval { $cb->(${$self->{_reason}}) };
        warn "on_disconnect callback error: $@" if $@;
        return;
    }

    push @{$self->{_callbacks}}, $cb;
}

=head2 _mark_disconnected

    $conn->_mark_disconnected($reason);

B<Internal method> - Called by the server when disconnect is detected.

Updates the connection state and invokes all registered callbacks.
Applications should not call this method directly.

State transitions occur in this order:

=over 4

=item 1. C<is_connected()> returns false

=item 2. C<disconnect_reason()> returns the reason string

=item 3. C<disconnect_future()> resolves with the reason (if it was created)

=item 4. C<on_disconnect> callbacks are invoked in registration order

=back

=cut

sub _mark_disconnected {
    my ($self, $reason) = @_;

    # Already disconnected - no-op (idempotent)
    return unless ${$self->{_connected}};

    # 1. Update state
    ${$self->{_connected}} = 0;
    ${$self->{_reason}} = $reason // 'unknown';

    # 2. Resolve future if it exists (lazy - may not have been created)
    if ($self->{_future} && !$self->{_future}->is_ready) {
        $self->{_future}->done(${$self->{_reason}});
    }

    # 3. Invoke callbacks
    for my $cb (@{$self->{_callbacks}}) {
        eval { $cb->(${$self->{_reason}}) };
        warn "on_disconnect callback error: $@" if $@;
    }

    # 4. Clear callbacks to release references
    $self->{_callbacks} = [];
}

1;

__END__

=head1 USAGE WITH PAGI::Request

The L<PAGI::Request> class provides convenience methods that delegate
to the connection object:

    my $req = PAGI::Request->new($scope, $receive);

    # Access connection object directly
    my $conn = $req->connection;

    # Convenience delegates
    $req->is_connected;                    # $conn->is_connected
    $req->is_disconnected;                 # !$conn->is_connected
    $req->disconnect_reason;               # $conn->disconnect_reason
    $req->on_disconnect(sub { ... });      # $conn->on_disconnect(...)
    $req->disconnect_future;               # $conn->disconnect_future

=head1 EXAMPLE: Basic Connection Check

    async sub handler {
        my ($scope, $receive, $send) = @_;
        my $conn = $scope->{'pagi.connection'};

        # Check before expensive work
        return unless $conn->is_connected;

        my $result = await expensive_operation();

        # Check again before responding
        return unless $conn->is_connected;

        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => $result, more => 0 });
    }

=head1 EXAMPLE: Cleanup on Disconnect

    async sub handler {
        my ($scope, $receive, $send) = @_;
        my $conn = $scope->{'pagi.connection'};

        my $temp_file = create_temp_file();
        my $lock = acquire_lock();

        # Register cleanup - runs automatically if client disconnects
        $conn->on_disconnect(sub {
            my ($reason) = @_;
            $temp_file->unlink;
            $lock->release;
            log_info("Client disconnected: $reason");
        });

        # Do work - cleanup happens automatically if client leaves
        my $result = await process_data($temp_file);

        # Normal cleanup on success
        $temp_file->unlink;
        $lock->release;

        await send_response($send, $result);
    }

=head1 SEE ALSO

L<PAGI::Request> - High-level request API with connection convenience methods

L<PAGI::Server> - Reference server implementation

L<PAGI::Server::Connection> - Per-connection state machine (internal)

=cut
