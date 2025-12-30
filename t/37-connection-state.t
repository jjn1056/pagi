#!/usr/bin/env perl

# =============================================================================
# Test: PAGI::Server::ConnectionState
#
# Verifies the connection state tracking object:
# 1. Initial state is connected
# 2. Disconnect transitions state correctly
# 3. on_disconnect callbacks work as expected
# 4. disconnect_future resolves correctly
# 5. Error handling in callbacks
# =============================================================================

use strict;
use warnings;
use Test2::V0;
use Future;

require PAGI::Server::ConnectionState;

# =============================================================================
# Test: Initial state
# =============================================================================

subtest 'initial state' => sub {
    my $conn = PAGI::Server::ConnectionState->new();

    ok($conn->is_connected, 'initially connected');
    is($conn->disconnect_reason, undef, 'no reason while connected');
    is($conn->disconnect_future, undef, 'no future when not provided');
};

# =============================================================================
# Test: Initial state with Future
# =============================================================================

subtest 'initial state with future' => sub {
    my $future = Future->new;
    my $conn = PAGI::Server::ConnectionState->new(future => $future);

    ok($conn->is_connected, 'initially connected');
    is($conn->disconnect_reason, undef, 'no reason while connected');
    ok($conn->disconnect_future, 'future returned when provided');
    ok(!$future->is_ready, 'future not ready initially');
};

# =============================================================================
# Test: Disconnect transitions state
# =============================================================================

subtest 'disconnect transitions state' => sub {
    my $conn = PAGI::Server::ConnectionState->new();

    $conn->_mark_disconnected('client_closed');

    ok(!$conn->is_connected, 'not connected after disconnect');
    is($conn->disconnect_reason, 'client_closed', 'reason is set');
};

# =============================================================================
# Test: Multiple disconnect calls are no-op
# =============================================================================

subtest 'multiple disconnects are no-op' => sub {
    my $conn = PAGI::Server::ConnectionState->new();
    my $cb_count = 0;

    $conn->on_disconnect(sub { $cb_count++ });

    $conn->_mark_disconnected('client_closed');
    $conn->_mark_disconnected('write_error');  # Should be ignored

    is($cb_count, 1, 'callback only invoked once');
    is($conn->disconnect_reason, 'client_closed', 'original reason preserved');
};

# =============================================================================
# Test: on_disconnect callbacks
# =============================================================================

subtest 'on_disconnect callbacks' => sub {
    my $conn = PAGI::Server::ConnectionState->new();
    my @calls;

    $conn->on_disconnect(sub { push @calls, ['cb1', @_] });
    $conn->on_disconnect(sub { push @calls, ['cb2', @_] });

    is(scalar @calls, 0, 'no calls while connected');

    $conn->_mark_disconnected('timeout');

    is(scalar @calls, 2, 'both callbacks invoked');
    is($calls[0], ['cb1', 'timeout'], 'cb1 called with reason');
    is($calls[1], ['cb2', 'timeout'], 'cb2 called with reason');
};

# =============================================================================
# Test: on_disconnect after already disconnected
# =============================================================================

subtest 'on_disconnect after already disconnected' => sub {
    my $conn = PAGI::Server::ConnectionState->new();
    $conn->_mark_disconnected('client_closed');

    my $called = 0;
    my $reason;
    $conn->on_disconnect(sub { $called = 1; $reason = $_[0] });

    ok($called, 'callback invoked immediately');
    is($reason, 'client_closed', 'reason passed');
};

# =============================================================================
# Test: disconnect_future resolves
# =============================================================================

subtest 'disconnect_future resolves' => sub {
    my $future = Future->new;
    my $conn = PAGI::Server::ConnectionState->new(future => $future);

    ok(!$future->is_ready, 'future pending initially');

    $conn->_mark_disconnected('write_error');

    ok($future->is_ready, 'future resolved after disconnect');
    is($future->get, 'write_error', 'future resolved with reason');
};

# =============================================================================
# Test: disconnect_future optional
# =============================================================================

subtest 'disconnect_future optional' => sub {
    my $conn = PAGI::Server::ConnectionState->new();  # No future
    is($conn->disconnect_future, undef, 'returns undef when not provided');
};

# =============================================================================
# Test: Callback errors do not break others
# =============================================================================

subtest 'callback errors do not break others' => sub {
    my $conn = PAGI::Server::ConnectionState->new();
    my $cb2_called = 0;

    $conn->on_disconnect(sub { die "error in cb1" });
    $conn->on_disconnect(sub { $cb2_called = 1 });

    # Should not die, should warn
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };

    $conn->_mark_disconnected('test');

    ok($cb2_called, 'cb2 still called despite cb1 error');
    like($warnings[0], qr/callback error/, 'warning emitted');
};

# =============================================================================
# Test: Callback error when registering after disconnect
# =============================================================================

subtest 'callback error when registering after disconnect' => sub {
    my $conn = PAGI::Server::ConnectionState->new();
    $conn->_mark_disconnected('client_closed');

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };

    $conn->on_disconnect(sub { die "error in late callback" });

    like($warnings[0], qr/callback error/, 'warning emitted for late callback');
};

# =============================================================================
# Test: All standard disconnect reasons
# =============================================================================

subtest 'standard disconnect reasons' => sub {
    my @reasons = qw(
        client_closed
        client_timeout
        idle_timeout
        write_timeout
        write_error
        read_error
        protocol_error
        server_shutdown
        body_too_large
    );

    for my $reason (@reasons) {
        my $conn = PAGI::Server::ConnectionState->new();
        $conn->_mark_disconnected($reason);
        is($conn->disconnect_reason, $reason, "reason '$reason' preserved");
    }
};

# =============================================================================
# Test: Future already ready is not touched
# =============================================================================

subtest 'future already ready is not touched' => sub {
    my $future = Future->done('pre-resolved');
    my $conn = PAGI::Server::ConnectionState->new(future => $future);

    # Should not die when trying to resolve already-resolved future
    $conn->_mark_disconnected('test');

    is($future->get, 'pre-resolved', 'original value preserved');
};

# =============================================================================
# Test: Server implements disconnect reason code paths (source inspection)
# =============================================================================

subtest 'server implements disconnect reason code paths' => sub {
    # Read the Connection.pm source
    my $source = do {
        open my $fh, '<', 'lib/PAGI/Server/Connection.pm' or die "Cannot read: $!";
        local $/;
        <$fh>;
    };

    # Verify protocol_error is set on parse failures
    like(
        $source,
        qr/_handle_disconnect\('protocol_error'\)/,
        'protocol_error reason used for parse failures'
    );

    # Verify server_shutdown auto-detection exists
    like(
        $source,
        qr/server_shutdown/,
        'server_shutdown reason is referenced'
    );

    like(
        $source,
        qr/\$self->\{server\}\{shutting_down\}/,
        'server shutdown state is checked'
    );
};

done_testing;
