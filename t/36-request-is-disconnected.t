#!/usr/bin/env perl

# =============================================================================
# Test: Request connection state methods (PAGI spec 0.3)
#
# Verifies that PAGI::Request connection methods work correctly:
# 1. is_connected / is_disconnected - synchronous, non-destructive
# 2. disconnect_reason - returns reason after disconnect
# 3. on_disconnect - callback registration
# 4. disconnect_future - Future that resolves on disconnect
# 5. connection - returns the ConnectionState object
# =============================================================================

use strict;
use warnings;
use Test2::V0;
use Future;

require PAGI::Request;
require PAGI::Server::ConnectionState;

# =============================================================================
# Test: Initial state - connected, no reason
# =============================================================================

subtest 'initially connected with no reason' => sub {
    my $conn = PAGI::Server::ConnectionState->new();
    my $req = PAGI::Request->new(
        { type => 'http', method => 'GET', path => '/', headers => [],
          'pagi.connection' => $conn },
        undef
    );

    ok($req->is_connected, 'is_connected returns true');
    ok(!$req->is_disconnected, 'is_disconnected returns false');
    is($req->disconnect_reason, undef, 'disconnect_reason is undef');
    is($req->connection, $conn, 'connection returns the object');
};

# =============================================================================
# Test: After disconnect - state changes
# =============================================================================

subtest 'after disconnect state changes' => sub {
    my $conn = PAGI::Server::ConnectionState->new();
    my $req = PAGI::Request->new(
        { type => 'http', method => 'GET', path => '/', headers => [],
          'pagi.connection' => $conn },
        undef
    );

    $conn->_mark_disconnected('client_closed');

    ok(!$req->is_connected, 'is_connected returns false');
    ok($req->is_disconnected, 'is_disconnected returns true');
    is($req->disconnect_reason, 'client_closed', 'disconnect_reason is set');
};

# =============================================================================
# Test: on_disconnect callback registration
# =============================================================================

subtest 'on_disconnect callbacks' => sub {
    my $conn = PAGI::Server::ConnectionState->new();
    my $req = PAGI::Request->new(
        { type => 'http', method => 'GET', path => '/', headers => [],
          'pagi.connection' => $conn },
        undef
    );

    my @called;
    $req->on_disconnect(sub { push @called, ['cb1', @_] });
    $req->on_disconnect(sub { push @called, ['cb2', @_] });

    is(scalar @called, 0, 'callbacks not called while connected');

    $conn->_mark_disconnected('idle_timeout');

    is(scalar @called, 2, 'both callbacks invoked');
    is($called[0], ['cb1', 'idle_timeout'], 'cb1 received reason');
    is($called[1], ['cb2', 'idle_timeout'], 'cb2 received reason');
};

# =============================================================================
# Test: on_disconnect after already disconnected
# =============================================================================

subtest 'on_disconnect after disconnect invokes immediately' => sub {
    my $conn = PAGI::Server::ConnectionState->new();
    $conn->_mark_disconnected('write_error');

    my $req = PAGI::Request->new(
        { type => 'http', method => 'GET', path => '/', headers => [],
          'pagi.connection' => $conn },
        undef
    );

    my $called = 0;
    my $reason;
    $req->on_disconnect(sub { $called = 1; $reason = $_[0] });

    ok($called, 'callback invoked immediately');
    is($reason, 'write_error', 'reason passed correctly');
};

# =============================================================================
# Test: disconnect_future resolves on disconnect
# =============================================================================

subtest 'disconnect_future resolves on disconnect' => sub {
    my $future = Future->new;
    my $conn = PAGI::Server::ConnectionState->new(future => $future);
    my $req = PAGI::Request->new(
        { type => 'http', method => 'GET', path => '/', headers => [],
          'pagi.connection' => $conn },
        undef
    );

    my $df = $req->disconnect_future;
    ok($df, 'disconnect_future returns a Future');
    ok(!$df->is_ready, 'Future not ready initially');

    $conn->_mark_disconnected('client_timeout');

    ok($df->is_ready, 'Future ready after disconnect');
    is($df->get, 'client_timeout', 'Future resolved with reason');
};

# =============================================================================
# Test: disconnect_future returns undef when not provided
# =============================================================================

subtest 'disconnect_future returns undef when not provided' => sub {
    my $conn = PAGI::Server::ConnectionState->new();  # No future
    my $req = PAGI::Request->new(
        { type => 'http', method => 'GET', path => '/', headers => [],
          'pagi.connection' => $conn },
        undef
    );

    is($req->disconnect_future, undef, 'returns undef');
};

# =============================================================================
# Test: No connection object returns safe defaults
# =============================================================================

subtest 'no connection object returns safe defaults' => sub {
    my $req = PAGI::Request->new(
        { type => 'http', method => 'GET', path => '/', headers => [] },
        undef
    );

    is($req->connection, undef, 'connection returns undef');
    ok(!$req->is_connected, 'is_connected returns false');
    ok($req->is_disconnected, 'is_disconnected returns true');
    is($req->disconnect_reason, undef, 'disconnect_reason returns undef');
    is($req->disconnect_future, undef, 'disconnect_future returns undef');

    # on_disconnect should not die
    my $died = 0;
    eval { $req->on_disconnect(sub { }); 1 } or $died = 1;
    ok(!$died, 'on_disconnect with no connection does not die');
};

# =============================================================================
# Test: Various disconnect reasons
# =============================================================================

subtest 'various disconnect reasons' => sub {
    my @reasons = qw(
        client_closed
        client_timeout
        idle_timeout
        write_error
        read_error
        protocol_error
        server_shutdown
        body_too_large
    );

    for my $reason (@reasons) {
        my $conn = PAGI::Server::ConnectionState->new();
        my $req = PAGI::Request->new(
            { type => 'http', method => 'GET', path => '/', headers => [],
              'pagi.connection' => $conn },
            undef
        );

        $conn->_mark_disconnected($reason);
        is($req->disconnect_reason, $reason, "reason '$reason' works");
    }
};

# =============================================================================
# Test: Synchronous nature - no async needed
# =============================================================================

subtest 'methods are synchronous' => sub {
    my $conn = PAGI::Server::ConnectionState->new();
    my $req = PAGI::Request->new(
        { type => 'http', method => 'GET', path => '/', headers => [],
          'pagi.connection' => $conn },
        undef
    );

    # These should all work without any async handling
    my $connected = $req->is_connected;
    my $disconnected = $req->is_disconnected;
    my $reason = $req->disconnect_reason;
    my $connection = $req->connection;

    ok($connected, 'is_connected is synchronous');
    ok(!$disconnected, 'is_disconnected is synchronous');
    is($reason, undef, 'disconnect_reason is synchronous');
    ok($connection, 'connection is synchronous');
};

done_testing;
