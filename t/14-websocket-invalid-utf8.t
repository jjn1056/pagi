#!/usr/bin/env perl

# =============================================================================
# Test: WebSocket Invalid UTF-8 Handling
#
# This test exposes issue 1.1 from SERVER_ISSUES.md:
# The server calls _send_close_frame() which doesn't exist, causing a crash
# when a WebSocket client sends invalid UTF-8 in a text frame.
#
# Per RFC 6455 Section 8.1:
# - Text frames must contain valid UTF-8
# - If invalid UTF-8 is received, server MUST close with status code 1007
#
# Expected behavior (after fix):
# - Server sends close frame with code 1007 ("Invalid frame payload data")
# - Connection closes gracefully
#
# Current behavior (before fix):
# - Server crashes with "Can't locate object method _send_close_frame"
# =============================================================================

use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use IO::Socket::INET;
use Future::AsyncAwait;
use FindBin;
use lib "$FindBin::Bin/../lib";

use PAGI::Server;

my $loop = IO::Async::Loop->new;

# Simple WebSocket echo app for testing
my $test_app = async sub  {
        my ($scope, $receive, $send) = @_;
    if ($scope->{type} eq 'lifespan') {
        while (1) {
            my $event = await $receive->();
            if ($event->{type} eq 'lifespan.startup') {
                await $send->({ type => 'lifespan.startup.complete' });
            }
            elsif ($event->{type} eq 'lifespan.shutdown') {
                await $send->({ type => 'lifespan.shutdown.complete' });
                last;
            }
        }
        return;
    }

    if ($scope->{type} eq 'websocket') {
        my $event = await $receive->();  # websocket.connect
        await $send->({ type => 'websocket.accept' });

        # Echo loop
        while (1) {
            my $msg = await $receive->();
            last if $msg->{type} eq 'websocket.disconnect';

            if (exists $msg->{text}) {
                await $send->({ type => 'websocket.send', text => "echo: $msg->{text}" });
            }
        }
    }
};

# Helper to create WebSocket frame
# Frame format (simplified for small payloads):
#   byte 0: FIN(1) + RSV(3) + opcode(4)
#   byte 1: MASK(1) + payload_len(7)
#   bytes 2-5: masking key (if MASK=1)
#   remaining: masked payload
sub make_websocket_frame {
    my ($opcode, $payload, $masked) = @_;
    $masked //= 1;

    my $frame = '';

    # First byte: FIN=1, RSV=0, opcode
    $frame .= chr(0x80 | $opcode);

    # Second byte: MASK + length
    my $len = length($payload);
    if ($len < 126) {
        $frame .= chr(($masked ? 0x80 : 0) | $len);
    }
    elsif ($len < 65536) {
        $frame .= chr(($masked ? 0x80 : 0) | 126);
        $frame .= pack('n', $len);
    }
    else {
        $frame .= chr(($masked ? 0x80 : 0) | 127);
        $frame .= pack('Q>', $len);
    }

    # Masking key and masked payload (clients MUST mask per RFC 6455)
    if ($masked) {
        my $mask = pack('N', int(rand(0xFFFFFFFF)));
        $frame .= $mask;

        my $masked_payload = '';
        for my $i (0 .. length($payload) - 1) {
            $masked_payload .= chr(ord(substr($payload, $i, 1)) ^ ord(substr($mask, $i % 4, 1)));
        }
        $frame .= $masked_payload;
    }
    else {
        $frame .= $payload;
    }

    return $frame;
}

# Helper to parse WebSocket close frame
sub parse_close_frame {
    my ($data) = @_;

    return unless length($data) >= 2;

    my $byte0 = ord(substr($data, 0, 1));
    my $byte1 = ord(substr($data, 1, 1));

    my $fin = ($byte0 & 0x80) >> 7;
    my $opcode = $byte0 & 0x0F;
    my $masked = ($byte1 & 0x80) >> 7;
    my $len = $byte1 & 0x7F;

    # Close frame has opcode 8
    return unless $opcode == 8;

    my $offset = 2;
    if ($len == 126) {
        $len = unpack('n', substr($data, 2, 2));
        $offset = 4;
    }
    elsif ($len == 127) {
        $len = unpack('Q>', substr($data, 2, 8));
        $offset = 10;
    }

    my $payload = substr($data, $offset, $len);

    # Close frame payload: 2-byte status code + optional reason
    my $status_code = undef;
    my $reason = '';
    if (length($payload) >= 2) {
        $status_code = unpack('n', substr($payload, 0, 2));
        $reason = substr($payload, 2) if length($payload) > 2;
    }

    return {
        opcode => $opcode,
        status_code => $status_code,
        reason => $reason,
    };
}

# =============================================================================
# Test: Send invalid UTF-8 in text frame
# =============================================================================
subtest 'Invalid UTF-8 in text frame should close with 1007' => sub {
    my $server = PAGI::Server->new(
        app   => $test_app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;
    my $port = $server->port;

    # Connect with raw socket
    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 5,
    );

    SKIP: {
        skip "Cannot connect to server", 3 unless $sock;

        # Send WebSocket upgrade request
        my $key = 'dGhlIHNhbXBsZSBub25jZQ==';
        print $sock "GET / HTTP/1.1\r\n";
        print $sock "Host: 127.0.0.1:$port\r\n";
        print $sock "Upgrade: websocket\r\n";
        print $sock "Connection: Upgrade\r\n";
        print $sock "Sec-WebSocket-Key: $key\r\n";
        print $sock "Sec-WebSocket-Version: 13\r\n";
        print $sock "\r\n";

        # Read upgrade response
        $sock->blocking(0);
        my $response = '';
        my $deadline = time + 3;
        while (time < $deadline) {
            my $buf;
            my $n = sysread($sock, $buf, 4096);
            if (defined $n && $n > 0) {
                $response .= $buf;
                last if $response =~ /\r\n\r\n/;
            }
            $loop->loop_once(0.1);
        }

        like($response, qr/HTTP\/1\.1 101/, 'WebSocket upgrade successful');

        # Now send a text frame (opcode 1) with INVALID UTF-8
        # 0xFF and 0xFE are never valid UTF-8 bytes
        # 0x80-0xBF are continuation bytes that can't start a sequence
        my $invalid_utf8 = "\xFF\xFE\x80\x81";

        my $text_frame = make_websocket_frame(1, $invalid_utf8);  # opcode 1 = text
        $sock->blocking(1);
        print $sock $text_frame;
        $sock->flush;

        # Read server response - should be a close frame with code 1007
        $sock->blocking(0);
        my $frame_data = '';
        $deadline = time + 3;
        while (time < $deadline) {
            my $buf;
            my $n = sysread($sock, $buf, 4096);
            if (defined $n && $n > 0) {
                $frame_data .= $buf;
                # Close frame is typically small, wait a bit for it
                last if length($frame_data) >= 4;
            }
            $loop->loop_once(0.1);
        }

        # Parse the close frame
        my $close_frame = parse_close_frame($frame_data);

        if ($close_frame) {
            is($close_frame->{opcode}, 8, 'Received close frame (opcode 8)');
            is($close_frame->{status_code}, 1007, 'Close code is 1007 (invalid UTF-8)');
        }
        else {
            fail('Did not receive close frame');
            fail('Close code check skipped');
            diag("Raw response data: " . unpack('H*', $frame_data));
        }

        close $sock;
    }

    $server->shutdown->get;
};

# =============================================================================
# Test: Valid UTF-8 should work normally
# =============================================================================
subtest 'Valid UTF-8 in text frame should echo correctly' => sub {
    my $server = PAGI::Server->new(
        app   => $test_app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;
    my $port = $server->port;

    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 5,
    );

    SKIP: {
        skip "Cannot connect to server", 2 unless $sock;

        # WebSocket handshake
        my $key = 'dGhlIHNhbXBsZSBub25jZQ==';
        print $sock "GET / HTTP/1.1\r\n";
        print $sock "Host: 127.0.0.1:$port\r\n";
        print $sock "Upgrade: websocket\r\n";
        print $sock "Connection: Upgrade\r\n";
        print $sock "Sec-WebSocket-Key: $key\r\n";
        print $sock "Sec-WebSocket-Version: 13\r\n";
        print $sock "\r\n";

        # Read upgrade response
        $sock->blocking(0);
        my $response = '';
        my $deadline = time + 3;
        while (time < $deadline) {
            my $buf;
            my $n = sysread($sock, $buf, 4096);
            if (defined $n && $n > 0) {
                $response .= $buf;
                last if $response =~ /\r\n\r\n/;
            }
            $loop->loop_once(0.1);
        }

        like($response, qr/HTTP\/1\.1 101/, 'WebSocket upgrade successful');

        # Send valid UTF-8 text (including multi-byte characters)
        my $valid_utf8 = "Hello \xC3\xA9\xC3\xA0\xC3\xB9";  # "Hello éàù" in UTF-8 bytes

        my $text_frame = make_websocket_frame(1, $valid_utf8);
        $sock->blocking(1);
        print $sock $text_frame;
        $sock->flush;

        # Read echo response
        $sock->blocking(0);
        my $frame_data = '';
        $deadline = time + 3;
        while (time < $deadline) {
            my $buf;
            my $n = sysread($sock, $buf, 4096);
            if (defined $n && $n > 0) {
                $frame_data .= $buf;
                last if length($frame_data) >= 10;  # Wait for some data
            }
            $loop->loop_once(0.1);
        }

        # Check we got a text frame back (opcode 1), not a close frame (opcode 8)
        my $opcode = ord(substr($frame_data, 0, 1)) & 0x0F if length($frame_data) > 0;
        is($opcode, 1, 'Received text frame back (not close frame)');

        close $sock;
    }

    $server->shutdown->get;
};

# =============================================================================
# Test: Server should not crash - can still accept new connections after bad one
# =============================================================================
subtest 'Server survives invalid UTF-8 and accepts new connections' => sub {
    my $server = PAGI::Server->new(
        app   => $test_app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;
    my $port = $server->port;

    # First connection: send invalid UTF-8
    {
        my $sock = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1',
            PeerPort => $port,
            Proto    => 'tcp',
            Timeout  => 5,
        );

        if ($sock) {
            my $key = 'dGhlIHNhbXBsZSBub25jZQ==';
            print $sock "GET / HTTP/1.1\r\n";
            print $sock "Host: 127.0.0.1:$port\r\n";
            print $sock "Upgrade: websocket\r\n";
            print $sock "Connection: Upgrade\r\n";
            print $sock "Sec-WebSocket-Key: $key\r\n";
            print $sock "Sec-WebSocket-Version: 13\r\n";
            print $sock "\r\n";

            $sock->blocking(0);
            my $deadline = time + 2;
            while (time < $deadline) {
                my $buf;
                sysread($sock, $buf, 4096);
                $loop->loop_once(0.1);
                last if $buf && $buf =~ /101/;
            }

            # Send invalid UTF-8
            my $bad_frame = make_websocket_frame(1, "\xFF\xFE");
            $sock->blocking(1);
            print $sock $bad_frame;

            # Give server time to process
            $loop->loop_once(0.5);
            close $sock;
        }
    }

    # Give the server a moment to recover
    $loop->loop_once(0.2);

    # Second connection: should still work
    my $second_works = 0;
    {
        my $sock = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1',
            PeerPort => $port,
            Proto    => 'tcp',
            Timeout  => 5,
        );

        if ($sock) {
            my $key = 'dGhlIHNhbXBsZSBub25jZQ==';
            print $sock "GET / HTTP/1.1\r\n";
            print $sock "Host: 127.0.0.1:$port\r\n";
            print $sock "Upgrade: websocket\r\n";
            print $sock "Connection: Upgrade\r\n";
            print $sock "Sec-WebSocket-Key: $key\r\n";
            print $sock "Sec-WebSocket-Version: 13\r\n";
            print $sock "\r\n";

            $sock->blocking(0);
            my $response = '';
            my $deadline = time + 3;
            while (time < $deadline) {
                my $buf;
                my $n = sysread($sock, $buf, 4096);
                $response .= $buf if defined $n && $n > 0;
                $loop->loop_once(0.1);
                last if $response =~ /101/;
            }

            $second_works = 1 if $response =~ /HTTP\/1\.1 101/;
            close $sock;
        }
    }

    ok($second_works, 'Server accepts new connections after handling invalid UTF-8');

    $server->shutdown->get;
};

done_testing;
