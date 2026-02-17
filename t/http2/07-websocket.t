use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use IO::Async::Stream;
use Future;
use Future::AsyncAwait;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Socket qw(AF_UNIX SOCK_STREAM);

plan skip_all => "Server integration tests not supported on Windows" if $^O eq 'MSWin32';
BEGIN {
    eval { require Net::HTTP2::nghttp2; Net::HTTP2::nghttp2->VERSION(0.007); 1 }
        or plan(skip_all => 'Net::HTTP2::nghttp2 0.007+ not installed (optional)');
}

# ============================================================
# Test: WebSocket over HTTP/2 (RFC 8441)
# ============================================================
# Verifies Extended CONNECT with :protocol=websocket for
# bootstrapping WebSocket connections over HTTP/2 streams.

use PAGI::Server::Connection;
use PAGI::Server;
use PAGI::Server::Protocol::HTTP1;
use PAGI::Server::Protocol::HTTP2;
use Protocol::WebSocket::Frame;

my $loop = IO::Async::Loop->new;
my $protocol = PAGI::Server::Protocol::HTTP1->new;

# ============================================================
# Helpers
# ============================================================

sub create_test_server {
    my (%args) = @_;
    my $server = PAGI::Server->new(
        app   => $args{app} // sub { },
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
        http2 => 1,
        %args,
    );
    $loop->add($server);
    return $server;
}

sub create_h2_connection {
    my (%overrides) = @_;

    socketpair(my $sock_a, my $sock_b, AF_UNIX, SOCK_STREAM, 0)
        or die "socketpair: $!";
    $sock_a->blocking(0);
    $sock_b->blocking(0);

    my $app = $overrides{app} // sub { };
    my $server = $overrides{server} // create_test_server(app => $app);

    my $stream = IO::Async::Stream->new(
        read_handle  => $sock_a,
        write_handle => $sock_a,
        on_read => sub { 0 },
    );

    my $conn = PAGI::Server::Connection->new(
        stream        => $stream,
        app           => $app,
        protocol      => $protocol,
        server        => $server,
        h2_protocol   => $server->{http2_protocol},
        alpn_protocol => 'h2',
    );

    $server->add_child($stream);
    $conn->start;

    return ($conn, $stream, $sock_b, $server);
}

sub create_client {
    my (%overrides) = @_;
    require Net::HTTP2::nghttp2::Session;
    return Net::HTTP2::nghttp2::Session->new_client(
        callbacks => {
            on_begin_headers   => $overrides{on_begin_headers}   // sub { 0 },
            on_header          => $overrides{on_header}          // sub { 0 },
            on_frame_recv      => $overrides{on_frame_recv}      // sub { 0 },
            on_data_chunk_recv => $overrides{on_data_chunk_recv} // sub { 0 },
            on_stream_close    => $overrides{on_stream_close}    // sub { 0 },
        },
    );
}

sub complete_h2_handshake {
    my ($client, $client_sock) = @_;

    $loop->loop_once(0.1);
    my $server_settings = '';
    $client_sock->sysread($server_settings, 4096);

    $client->send_connection_preface;
    my $data = $client->mem_send;
    $client_sock->syswrite($data);
    $loop->loop_once(0.1);

    $client->mem_recv($server_settings);

    $loop->loop_once(0.1);
    my $ack = '';
    $client_sock->sysread($ack, 4096);
    $client->mem_recv($ack) if length($ack);

    my $client_ack = $client->mem_send;
    $client_sock->syswrite($client_ack) if length($client_ack);
    $loop->loop_once(0.1);

    my $extra = '';
    $client_sock->sysread($extra, 4096);
    $client->mem_recv($extra) if length($extra);
}

sub read_response {
    my ($client, $client_sock, $rounds) = @_;
    $rounds //= 10;
    for (1..$rounds) {
        $loop->loop_once(0.1);
        my $data = '';
        $client_sock->sysread($data, 8192);
        $client->mem_recv($data) if length($data);
    }
}

# Helper: send data on an HTTP/2 stream (raw DATA frame via nghttp2)
sub send_stream_data {
    my ($client, $client_sock, $stream_id, $data, $end_stream) = @_;
    $end_stream //= 0;
    $client->submit_data($stream_id, $data, $end_stream);
    my $out = $client->mem_send;
    $client_sock->syswrite($out) if length($out);
}

# Helper: read data from client socket until we get enough rounds
sub exchange_frames {
    my ($client, $client_sock, $rounds) = @_;
    $rounds //= 10;
    for (1..$rounds) {
        $loop->loop_once(0.1);
        my $buf = '';
        $client_sock->sysread($buf, 16384);
        $client->mem_recv($buf) if length($buf);
        my $out = $client->mem_send;
        $client_sock->syswrite($out) if length($out);
    }
}

# ============================================================
# Server advertises SETTINGS_ENABLE_CONNECT_PROTOCOL
# ============================================================
subtest 'Server advertises ENABLE_CONNECT_PROTOCOL in SETTINGS' => sub {
    my ($conn, $stream, $client_sock, $server) = create_h2_connection();

    # Read the initial SETTINGS frame from server
    $loop->loop_once(0.1);
    my $settings_data = '';
    $client_sock->sysread($settings_data, 4096);

    ok(length($settings_data) > 0, 'Server sent initial SETTINGS');

    # The SETTINGS frame should include ENABLE_CONNECT_PROTOCOL=1
    # SETTINGS frame format: 9-byte header + 6 bytes per setting
    # Setting ID 0x08 (ENABLE_CONNECT_PROTOCOL) with value 1
    # Check the raw bytes for this setting
    my $found_connect_protocol = 0;
    # Parse the SETTINGS frame (skip the 9-byte frame header)
    if (length($settings_data) >= 9) {
        my $payload_len = (ord(substr($settings_data, 0, 1)) << 16)
                        | (ord(substr($settings_data, 1, 1)) << 8)
                        | ord(substr($settings_data, 2, 1));
        my $frame_type = ord(substr($settings_data, 3, 1));

        if ($frame_type == 4) {  # SETTINGS frame type
            my $offset = 9;  # Skip 9-byte header
            while ($offset + 6 <= 9 + $payload_len) {
                my $id = unpack('n', substr($settings_data, $offset, 2));
                my $val = unpack('N', substr($settings_data, $offset + 2, 4));
                if ($id == 8 && $val == 1) {  # ENABLE_CONNECT_PROTOCOL
                    $found_connect_protocol = 1;
                }
                $offset += 6;
            }
        }
    }

    ok($found_connect_protocol,
        'SETTINGS includes ENABLE_CONNECT_PROTOCOL=1');

    $stream->close_now;
    $loop->remove($server);
};

# ============================================================
# Extended CONNECT → app receives websocket scope
# ============================================================
subtest 'Extended CONNECT creates websocket scope' => sub {
    my @scopes;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        push @scopes, $scope;

        if ($scope->{type} eq 'websocket') {
            # Accept the WebSocket connection
            await $send->({
                type => 'websocket.accept',
            });

            # Receive connect event
            my $event = await $receive->();

            # Wait for disconnect
            while ($event->{type} ne 'websocket.disconnect') {
                $event = await $receive->();
            }
        }
    };

    my ($conn, $stream, $client_sock, $server) = create_h2_connection(app => $app);

    my %response_headers;
    my $response_data = '';

    my $client = create_client(
        on_header => sub {
            my ($sid, $name, $value) = @_;
            $response_headers{$name} = $value;
            return 0;
        },
        on_data_chunk_recv => sub {
            my ($sid, $data) = @_;
            $response_data .= $data;
            return 0;
        },
    );

    complete_h2_handshake($client, $client_sock);

    # Send Extended CONNECT for WebSocket (RFC 8441)
    $client->submit_request(
        method    => 'CONNECT',
        path      => '/ws/chat',
        scheme    => 'https',
        authority => 'localhost',
        headers   => [
            [':protocol', 'websocket'],
            ['sec-websocket-version', '13'],
            ['sec-websocket-protocol', 'chat, superchat'],
            ['origin', 'https://localhost'],
        ],
        body      => sub { return undef },  # streaming: keep open
    );
    $client_sock->syswrite($client->mem_send);

    exchange_frames($client, $client_sock);

    ok(scalar @scopes >= 1, 'App was called');

    if (@scopes) {
        my $scope = $scopes[0];
        is($scope->{type}, 'websocket', 'scope type is websocket');
        is($scope->{http_version}, '2', 'http_version is 2');
        is($scope->{path}, '/ws/chat', 'path is /ws/chat');
        is($scope->{scheme}, 'ws', 'scheme is ws (WebSocket, no TLS in test)');
        ok(ref $scope->{headers} eq 'ARRAY', 'headers is array');
        ok(ref $scope->{subprotocols} eq 'ARRAY', 'subprotocols is array');
        is(scalar @{$scope->{subprotocols}}, 2, 'Two subprotocols');
        is($scope->{subprotocols}[0], 'chat', 'First subprotocol');
        is($scope->{subprotocols}[1], 'superchat', 'Second subprotocol');
    }

    # Server should have responded with 200 (not 101)
    is($response_headers{':status'}, '200', 'Server responded with 200');

    $stream->close_now;
    $loop->remove($server);
};

# ============================================================
# Bidirectional text message exchange
# ============================================================
subtest 'Bidirectional text message exchange' => sub {
    my @received_messages;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;

        if ($scope->{type} eq 'websocket') {
            await $send->({ type => 'websocket.accept' });

            # Read connect event
            my $event = await $receive->();
            next unless $event->{type} eq 'websocket.connect';

            # Echo loop
            while (1) {
                $event = await $receive->();
                if ($event->{type} eq 'websocket.receive') {
                    push @received_messages, $event;
                    # Echo back
                    await $send->({
                        type => 'websocket.send',
                        text => "echo: $event->{text}",
                    });
                }
                elsif ($event->{type} eq 'websocket.disconnect') {
                    last;
                }
            }
        }
    };

    my ($conn, $stream_io, $client_sock, $server) = create_h2_connection(app => $app);

    my %response_headers;
    my $ws_data = '';  # Raw DATA frames received on the WS stream

    my $client = create_client(
        on_header => sub {
            my ($sid, $name, $value) = @_;
            $response_headers{$name} = $value;
            return 0;
        },
        on_data_chunk_recv => sub {
            my ($sid, $data) = @_;
            $ws_data .= $data;
            return 0;
        },
    );

    complete_h2_handshake($client, $client_sock);

    # Send Extended CONNECT
    my $ws_stream_id = $client->submit_request(
        method    => 'CONNECT',
        path      => '/ws/echo',
        scheme    => 'https',
        authority => 'localhost',
        headers   => [
            [':protocol', 'websocket'],
            ['sec-websocket-version', '13'],
        ],
        body      => sub { return undef },  # streaming: keep open
    );
    $client_sock->syswrite($client->mem_send);

    # Wait for 200 response
    exchange_frames($client, $client_sock);
    is($response_headers{':status'}, '200', 'Got 200 for WebSocket accept');

    # Send a WebSocket text frame via HTTP/2 DATA
    my $ws_frame = Protocol::WebSocket::Frame->new(
        buffer => 'Hello WebSocket',
        type   => 'text',
        masked => 1,
    );
    my $frame_bytes = $ws_frame->to_bytes;

    send_stream_data($client, $client_sock, $ws_stream_id, $frame_bytes);

    # Read the echo response
    $ws_data = '';
    exchange_frames($client, $client_sock);

    # Parse the server's WebSocket frame from the DATA
    ok(length($ws_data) > 0, 'Received data from server');
    if (length($ws_data) > 0) {
        my $response_frame = Protocol::WebSocket::Frame->new;
        $response_frame->append($ws_data);
        my $text = $response_frame->next_bytes;
        is($text, 'echo: Hello WebSocket', 'Got echoed message');
    }

    ok(scalar @received_messages >= 1, 'Server received message');
    is($received_messages[0]{text}, 'Hello WebSocket', 'Server got correct text');

    $stream_io->close_now;
    $loop->remove($server);
};

# ============================================================
# Close handshake
# ============================================================
subtest 'WebSocket close handshake over HTTP/2' => sub {
    my $disconnect_event;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;

        if ($scope->{type} eq 'websocket') {
            await $send->({ type => 'websocket.accept' });
            my $event = await $receive->();  # websocket.connect

            # Wait for disconnect
            while (1) {
                $event = await $receive->();
                if ($event->{type} eq 'websocket.disconnect') {
                    $disconnect_event = $event;
                    last;
                }
            }
        }
    };

    my ($conn, $stream_io, $client_sock, $server) = create_h2_connection(app => $app);

    my %response_headers;
    my $ws_data = '';
    my $stream_closed = 0;

    my $client = create_client(
        on_header => sub {
            my ($sid, $name, $value) = @_;
            $response_headers{$name} = $value;
            return 0;
        },
        on_data_chunk_recv => sub {
            my ($sid, $data) = @_;
            $ws_data .= $data;
            return 0;
        },
        on_stream_close => sub {
            $stream_closed = 1;
            return 0;
        },
    );

    complete_h2_handshake($client, $client_sock);

    # Open WebSocket
    my $ws_stream_id = $client->submit_request(
        method    => 'CONNECT',
        path      => '/ws/close-test',
        scheme    => 'https',
        authority => 'localhost',
        headers   => [
            [':protocol', 'websocket'],
            ['sec-websocket-version', '13'],
        ],
        body      => sub { return undef },  # streaming: keep open
    );
    $client_sock->syswrite($client->mem_send);
    exchange_frames($client, $client_sock);

    is($response_headers{':status'}, '200', 'WebSocket accepted');

    # Send close frame (code=1000, reason="normal closure")
    my $close_frame = Protocol::WebSocket::Frame->new(
        type   => 'close',
        buffer => pack('n', 1000) . 'normal closure',
        masked => 1,
    );
    send_stream_data($client, $client_sock, $ws_stream_id, $close_frame->to_bytes);

    exchange_frames($client, $client_sock);

    # Server should have received the disconnect event
    ok(defined $disconnect_event, 'Server got disconnect event');
    if ($disconnect_event) {
        is($disconnect_event->{code}, 1000, 'Close code is 1000');
        is($disconnect_event->{reason}, 'normal closure', 'Close reason matches');
    }

    # Server should have sent close frame back
    if (length($ws_data) > 0) {
        my $frame = Protocol::WebSocket::Frame->new;
        $frame->append($ws_data);
        my $bytes = $frame->next_bytes;
        # Close frame echo
        ok(defined $bytes, 'Server sent close frame response');
    }

    $stream_io->close_now;
    $loop->remove($server);
};

done_testing;
