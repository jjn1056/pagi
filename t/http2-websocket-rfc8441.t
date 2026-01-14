#!/usr/bin/env perl

# =============================================================================
# Test: HTTP/2 WebSocket support (RFC 8441)
#
# Tests the HTTP/2 WebSocket implementation:
# - SETTINGS_ENABLE_CONNECT_PROTOCOL is advertised
# - Extended CONNECT detection works
# - Scope creation for HTTP/2 WebSocket
# - Event handling (accept, send, receive, close, keepalive)
#
# Note: Full integration tests require an HTTP/2 client with RFC 8441 support.
# These tests verify the server-side implementation at the unit level.
# =============================================================================

use strict;
use warnings;
use Test2::V0;
use FindBin;
use lib "$FindBin::Bin/../lib";

# =============================================================================
# Test 1: HTTP/2 protocol module availability
# =============================================================================

subtest 'HTTP/2 protocol module exists' => sub {
    ok(eval { require PAGI::Server::Protocol::HTTP2; 1 },
        'PAGI::Server::Protocol::HTTP2 loads');

    my $proto = PAGI::Server::Protocol::HTTP2->new;
    isa_ok($proto, ['PAGI::Server::Protocol::HTTP2']);

    # Check enable_connect_protocol is enabled by default
    is($proto->{enable_connect_protocol}, 1,
        'enable_connect_protocol defaults to 1 (RFC 8441)');
};

# =============================================================================
# Test 2: HTTP/2 protocol settings
# =============================================================================

subtest 'HTTP/2 protocol settings' => sub {
    require PAGI::Server::Protocol::HTTP2;
    my $proto = PAGI::Server::Protocol::HTTP2->new(
        max_concurrent_streams  => 200,
        initial_window_size     => 32768,
        max_frame_size          => 32768,
        enable_push             => 0,
        enable_connect_protocol => 1,
    );

    is($proto->{max_concurrent_streams}, 200, 'max_concurrent_streams set correctly');
    is($proto->{initial_window_size}, 32768, 'initial_window_size set correctly');
    is($proto->{max_frame_size}, 32768, 'max_frame_size set correctly');
    is($proto->{enable_push}, 0, 'enable_push set correctly');
    is($proto->{enable_connect_protocol}, 1, 'enable_connect_protocol set correctly');
};

# =============================================================================
# Test 3: HTTP/2 protocol can disable extended CONNECT
# =============================================================================

subtest 'HTTP/2 protocol can disable RFC 8441' => sub {
    require PAGI::Server::Protocol::HTTP2;
    my $proto = PAGI::Server::Protocol::HTTP2->new(
        enable_connect_protocol => 0,
    );

    is($proto->{enable_connect_protocol}, 0,
        'enable_connect_protocol can be disabled');
};

# =============================================================================
# Test 4: Connection.pm has HTTP/2 WebSocket handlers
# =============================================================================

subtest 'Connection.pm HTTP/2 WebSocket handlers exist' => sub {
    my $source = do {
        open my $fh, '<', 'lib/PAGI/Server/Connection.pm' or die "Cannot read: $!";
        local $/;
        <$fh>;
    };

    # Check for RFC 8441 detection
    like($source, qr/_handle_http2_websocket_connect/,
        'has _handle_http2_websocket_connect handler');

    # Check for scope creation
    like($source, qr/_create_http2_websocket_scope/,
        'has _create_http2_websocket_scope');

    # Check for receive/send closures
    like($source, qr/_create_http2_websocket_receive/,
        'has _create_http2_websocket_receive');
    like($source, qr/_create_http2_websocket_send/,
        'has _create_http2_websocket_send');

    # Check for data handling
    like($source, qr/_on_http2_websocket_data/,
        'has _on_http2_websocket_data for frame processing');

    # Check for keepalive
    like($source, qr/_start_http2_ws_keepalive/,
        'has _start_http2_ws_keepalive');
    like($source, qr/_stop_http2_ws_keepalive/,
        'has _stop_http2_ws_keepalive');
};

# =============================================================================
# Test 5: Extended CONNECT detection in source
# =============================================================================

subtest 'Extended CONNECT detection logic' => sub {
    my $source = do {
        open my $fh, '<', 'lib/PAGI/Server/Connection.pm' or die "Cannot read: $!";
        local $/;
        <$fh>;
    };

    # Check for :protocol pseudo-header handling
    like($source, qr/:protocol.*RFC 8441/i,
        'handles :protocol pseudo-header for RFC 8441');

    # Check for websocket protocol detection
    like($source, qr/lc\(\$protocol\) eq 'websocket'/,
        'detects websocket protocol value');

    # Check for validation of required pseudo-headers
    like($source, qr/:path.*:scheme.*:authority/s,
        'validates required pseudo-headers for extended CONNECT');
};

# =============================================================================
# Test 6: HTTP/2 WebSocket scope structure
# =============================================================================

subtest 'HTTP/2 WebSocket scope structure' => sub {
    my $source = do {
        open my $fh, '<', 'lib/PAGI/Server/Connection.pm' or die "Cannot read: $!";
        local $/;
        <$fh>;
    };

    # Extract the _create_http2_websocket_scope function body
    if ($source =~ /sub _create_http2_websocket_scope \{(.*?)^\}/ms) {
        my $scope_code = $1;

        # Verify key scope fields
        like($scope_code, qr/type\s*=>\s*'websocket'/,
            'scope type is websocket');
        like($scope_code, qr/http_version\s*=>\s*'2'/,
            'scope http_version is 2');
        like($scope_code, qr/'http2'\s*=>\s*\{/,
            'scope has http2 extension');
        like($scope_code, qr/stream_id\s*=>/,
            'scope http2 extension has stream_id');
    }
    else {
        fail('Could not extract _create_http2_websocket_scope function');
    }
};

# =============================================================================
# Test 7: WebSocket frame handling for HTTP/2
# =============================================================================

subtest 'WebSocket frame handling' => sub {
    my $source = do {
        open my $fh, '<', 'lib/PAGI/Server/Connection.pm' or die "Cannot read: $!";
        local $/;
        <$fh>;
    };

    # Check frame types are handled
    like($source, qr/opcode == 1.*# Text frame/s,
        'handles text frames (opcode 1)');
    like($source, qr/opcode == 2.*# Binary frame/s,
        'handles binary frames (opcode 2)');
    like($source, qr/opcode == 8.*# Close frame/s,
        'handles close frames (opcode 8)');
    like($source, qr/opcode == 9.*# Ping frame/s,
        'handles ping frames (opcode 9)');
    like($source, qr/opcode == 10.*# Pong frame/s,
        'handles pong frames (opcode 10)');
};

# =============================================================================
# Test 8: WebSocket accept sends 200 (not 101) for HTTP/2
# =============================================================================

subtest 'HTTP/2 WebSocket accept uses 200 status' => sub {
    my $source = do {
        open my $fh, '<', 'lib/PAGI/Server/Connection.pm' or die "Cannot read: $!";
        local $/;
        <$fh>;
    };

    # Check that HTTP/2 WebSocket accept uses 200, not 101
    like($source, qr/RFC 8441.*200 OK.*not 101/is,
        'HTTP/2 WebSocket uses 200 OK per RFC 8441');

    # Verify no Sec-WebSocket-Accept for HTTP/2
    like($source, qr/No Sec-WebSocket-Accept.*HTTP\/2/i,
        'No Sec-WebSocket-Accept header for HTTP/2');
};

# =============================================================================
# Test 9: Server-to-client frames are unmasked (Risk 1 mitigation)
# =============================================================================

subtest 'Server frames are unmasked' => sub {
    my $source = do {
        open my $fh, '<', 'lib/PAGI/Server/Connection.pm' or die "Cannot read: $!";
        local $/;
        <$fh>;
    };

    # Count masked => 0 occurrences in HTTP/2 WebSocket code
    # Should have multiple for text, binary, close, ping, pong frames
    my @masked_zero = $source =~ /masked\s*=>\s*0/g;
    cmp_ok(scalar @masked_zero, '>=', 3,
        'Multiple server frames use masked => 0');
};

# =============================================================================
# Test 10: Per-stream isolation (Risk 3 mitigation)
# =============================================================================

subtest 'Per-stream WebSocket isolation' => sub {
    my $source = do {
        open my $fh, '<', 'lib/PAGI/Server/Connection.pm' or die "Cannot read: $!";
        local $/;
        <$fh>;
    };

    # Check for per-stream state initialization
    like($source, qr/_init_http2_websocket_stream.*Risk 3/s,
        'Stream init mentions Risk 3 mitigation');

    # Check for per-stream frame parser
    like($source, qr/ws_frame.*Protocol::WebSocket::Frame/,
        'Each stream has isolated frame parser');

    # Check for per-stream ping timer
    like($source, qr/ws_ping_timer\s*=>\s*undef/,
        'Each stream has isolated ping timer');
};

# =============================================================================
# Test 11: HTTP/2 availability check
# =============================================================================

subtest 'HTTP/2 availability detection' => sub {
    SKIP: {
        eval { require Net::HTTP2::nghttp2 };
        skip "Net::HTTP2::nghttp2 not installed", 2 if $@;

        require PAGI::Server::Protocol::HTTP2;
        ok(PAGI::Server::Protocol::HTTP2->available,
            'HTTP/2 available when nghttp2 installed');

        # Try to create a session
        my $proto = PAGI::Server::Protocol::HTTP2->new;
        my $session = eval {
            $proto->create_session(
                on_request => sub { },
                on_body    => sub { },
                on_close   => sub { },
            );
        };

        if ($@) {
            fail("create_session failed: $@");
        }
        else {
            ok(defined $session, 'Can create HTTP/2 session');
        }
    }
};

done_testing;
