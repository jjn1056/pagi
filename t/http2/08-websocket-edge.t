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
    eval { require Net::HTTP2::nghttp2; 1 }
        or plan(skip_all => 'Net::HTTP2::nghttp2 not installed (optional)');
}

# ============================================================
# Test: WebSocket over HTTP/2 Edge Cases
# ============================================================
# Covers binary messages, server-initiated close, large messages,
# and multiple concurrent WebSocket streams on one HTTP/2 connection.

use PAGI::Server::Connection;
use PAGI::Server;
use PAGI::Server::Protocol::HTTP1;
use PAGI::Server::Protocol::HTTP2;
use Protocol::WebSocket::Frame;

my $loop = IO::Async::Loop->new;
my $protocol = PAGI::Server::Protocol::HTTP1->new;

# ============================================================
# Helpers (shared with 07-websocket.t)
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

sub send_stream_data {
    my ($client, $client_sock, $stream_id, $data, $end_stream) = @_;
    $end_stream //= 0;
    $client->submit_data($stream_id, $data, $end_stream);
    my $out = $client->mem_send;
    _drain_write($client_sock, $out) if length($out);
}

# Write all bytes to a non-blocking socket, looping on partial writes
sub _drain_write {
    my ($sock, $data) = @_;
    my $offset = 0;
    while ($offset < length($data)) {
        my $written = $sock->syswrite($data, length($data) - $offset, $offset);
        if (defined $written) {
            $offset += $written;
        } else {
            # EAGAIN/EWOULDBLOCK — let the event loop drain the read side
            $loop->loop_once(0.05);
        }
    }
}

sub exchange_frames {
    my ($client, $client_sock, $rounds) = @_;
    $rounds //= 10;
    for (1..$rounds) {
        $loop->loop_once(0.1);
        my $buf = '';
        $client_sock->sysread($buf, 16384);
        $client->mem_recv($buf) if length($buf);
        my $out = $client->mem_send;
        _drain_write($client_sock, $out) if length($out);
    }
}

# Open a WebSocket stream and return the stream ID after 200 response
sub open_ws_stream {
    my ($client, $client_sock, $path) = @_;
    $path //= '/ws';

    my $ws_stream_id = $client->submit_request(
        method    => 'CONNECT',
        path      => $path,
        scheme    => 'https',
        authority => 'localhost',
        headers   => [
            [':protocol', 'websocket'],
            ['sec-websocket-version', '13'],
        ],
        body      => sub { return undef },
    );
    $client_sock->syswrite($client->mem_send);
    exchange_frames($client, $client_sock);

    return $ws_stream_id;
}

# ============================================================
# Binary message echo
# ============================================================
subtest 'Binary message echo over HTTP/2 WebSocket' => sub {
    my @received_messages;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;

        if ($scope->{type} eq 'websocket') {
            await $send->({ type => 'websocket.accept' });
            my $event = await $receive->();  # websocket.connect

            while (1) {
                $event = await $receive->();
                if ($event->{type} eq 'websocket.receive') {
                    push @received_messages, $event;
                    # Echo binary back
                    if (defined $event->{bytes}) {
                        await $send->({
                            type  => 'websocket.send',
                            bytes => $event->{bytes},
                        });
                    }
                }
                elsif ($event->{type} eq 'websocket.disconnect') {
                    last;
                }
            }
        }
    };

    my ($conn, $stream_io, $client_sock, $server) = create_h2_connection(app => $app);
    my $ws_data = '';

    my $client = create_client(
        on_data_chunk_recv => sub {
            my ($sid, $data) = @_;
            $ws_data .= $data;
            return 0;
        },
    );

    complete_h2_handshake($client, $client_sock);
    my $ws_stream_id = open_ws_stream($client, $client_sock);

    # Send binary data (non-UTF8 bytes)
    my $binary_data = pack('C*', 0x00, 0xFF, 0x80, 0x7F, 0xDE, 0xAD, 0xBE, 0xEF);
    my $ws_frame = Protocol::WebSocket::Frame->new(
        buffer => $binary_data,
        type   => 'binary',
        masked => 1,
    );
    send_stream_data($client, $client_sock, $ws_stream_id, $ws_frame->to_bytes);

    $ws_data = '';
    exchange_frames($client, $client_sock);

    ok(length($ws_data) > 0, 'Received binary echo from server');
    if (length($ws_data) > 0) {
        my $response_frame = Protocol::WebSocket::Frame->new;
        $response_frame->append($ws_data);
        my $bytes = $response_frame->next_bytes;
        is($bytes, $binary_data, 'Binary data echoed correctly');
    }

    ok(scalar @received_messages >= 1, 'Server received binary message');
    ok(defined $received_messages[0]{bytes}, 'Message has bytes field');
    is($received_messages[0]{bytes}, $binary_data, 'Server got correct binary data');

    $stream_io->close_now;
    $loop->remove($server);
};

# ============================================================
# Server-initiated close
# ============================================================
subtest 'Server-initiated close over HTTP/2' => sub {
    my $ws_data = '';
    my $stream_closed = 0;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;

        if ($scope->{type} eq 'websocket') {
            await $send->({ type => 'websocket.accept' });
            my $event = await $receive->();  # websocket.connect

            # Server immediately closes the connection
            await $send->({
                type   => 'websocket.close',
                code   => 1000,
                reason => 'server done',
            });
        }
    };

    my ($conn, $stream_io, $client_sock, $server) = create_h2_connection(app => $app);

    my $client = create_client(
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
    # The app runs accept → connect → close synchronously during open_ws_stream's exchange
    my $ws_stream_id = open_ws_stream($client, $client_sock);

    # Close frame data was already received during open_ws_stream
    ok(length($ws_data) > 0, 'Received close frame from server');
    if (length($ws_data) > 0) {
        my $frame = Protocol::WebSocket::Frame->new;
        $frame->append($ws_data);
        my $bytes = $frame->next_bytes;
        ok(defined $bytes, 'Parsed close frame');
        if (defined $bytes && length($bytes) >= 2) {
            my $code = unpack('n', substr($bytes, 0, 2));
            my $reason = substr($bytes, 2);
            is($code, 1000, 'Close code is 1000');
            is($reason, 'server done', 'Close reason matches');
        }
    }

    $stream_io->close_now;
    $loop->remove($server);
};

# ============================================================
# Large message (tests flow control / chunking)
# ============================================================
subtest 'Large message over HTTP/2 WebSocket' => sub {
    my $received_text;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;

        if ($scope->{type} eq 'websocket') {
            await $send->({ type => 'websocket.accept' });
            my $event = await $receive->();  # websocket.connect

            $event = await $receive->();
            if ($event->{type} eq 'websocket.receive') {
                $received_text = $event->{text};
                # Echo it back
                await $send->({
                    type => 'websocket.send',
                    text => $event->{text},
                });
            }

            # Wait for disconnect
            $event = await $receive->();
        }
    };

    my ($conn, $stream_io, $client_sock, $server) = create_h2_connection(app => $app);
    my $ws_data = '';

    my $client = create_client(
        on_data_chunk_recv => sub {
            my ($sid, $data) = @_;
            $ws_data .= $data;
            return 0;
        },
    );

    complete_h2_handshake($client, $client_sock);
    my $ws_stream_id = open_ws_stream($client, $client_sock);

    # Send a large message (32KB — exceeds default DATA frame size but within flow control window)
    my $large_text = 'A' x 32768;
    my $ws_frame = Protocol::WebSocket::Frame->new(
        buffer => $large_text,
        type   => 'text',
        masked => 1,
    );
    send_stream_data($client, $client_sock, $ws_stream_id, $ws_frame->to_bytes);

    $ws_data = '';
    exchange_frames($client, $client_sock, 20);

    is($received_text, $large_text, 'Server received full large message');

    ok(length($ws_data) > 0, 'Received echoed large message');
    if (length($ws_data) > 0) {
        my $response_frame = Protocol::WebSocket::Frame->new;
        $response_frame->append($ws_data);
        my $text = $response_frame->next_bytes;
        is(length($text), 32768, 'Echoed message is correct length');
        is($text, $large_text, 'Echoed message content matches');
    }

    $stream_io->close_now;
    $loop->remove($server);
};

# ============================================================
# Multiple concurrent WebSocket streams on one connection
# ============================================================
subtest 'Multiple concurrent WebSocket streams' => sub {
    my %stream_messages;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;

        if ($scope->{type} eq 'websocket') {
            await $send->({ type => 'websocket.accept' });
            my $event = await $receive->();  # websocket.connect

            while (1) {
                $event = await $receive->();
                if ($event->{type} eq 'websocket.receive') {
                    # Echo back with path prefix
                    await $send->({
                        type => 'websocket.send',
                        text => "$scope->{path}: $event->{text}",
                    });
                }
                elsif ($event->{type} eq 'websocket.disconnect') {
                    last;
                }
            }
        }
    };

    my ($conn, $stream_io, $client_sock, $server) = create_h2_connection(app => $app);

    my %ws_data;
    my $client = create_client(
        on_data_chunk_recv => sub {
            my ($sid, $data) = @_;
            $ws_data{$sid} //= '';
            $ws_data{$sid} .= $data;
            return 0;
        },
    );

    complete_h2_handshake($client, $client_sock);

    # Open two WebSocket streams on the same connection
    my $ws1_id = open_ws_stream($client, $client_sock, '/ws/stream1');
    my $ws2_id = open_ws_stream($client, $client_sock, '/ws/stream2');

    ok($ws1_id != $ws2_id, 'Two different stream IDs');

    # Send message on stream 1
    my $frame1 = Protocol::WebSocket::Frame->new(
        buffer => 'hello from 1',
        type   => 'text',
        masked => 1,
    );
    send_stream_data($client, $client_sock, $ws1_id, $frame1->to_bytes);

    # Send message on stream 2
    my $frame2 = Protocol::WebSocket::Frame->new(
        buffer => 'hello from 2',
        type   => 'text',
        masked => 1,
    );
    send_stream_data($client, $client_sock, $ws2_id, $frame2->to_bytes);

    %ws_data = ();
    exchange_frames($client, $client_sock);

    # Parse responses from each stream
    my ($text1, $text2);
    if ($ws_data{$ws1_id} && length($ws_data{$ws1_id}) > 0) {
        my $f = Protocol::WebSocket::Frame->new;
        $f->append($ws_data{$ws1_id});
        $text1 = $f->next_bytes;
    }
    if ($ws_data{$ws2_id} && length($ws_data{$ws2_id}) > 0) {
        my $f = Protocol::WebSocket::Frame->new;
        $f->append($ws_data{$ws2_id});
        $text2 = $f->next_bytes;
    }

    is($text1, '/ws/stream1: hello from 1', 'Stream 1 echoed with correct path');
    is($text2, '/ws/stream2: hello from 2', 'Stream 2 echoed with correct path');

    $stream_io->close_now;
    $loop->remove($server);
};

# ============================================================
# WebSocket rejection (no accept) over HTTP/2
# ============================================================
subtest 'WebSocket rejection over HTTP/2' => sub {
    my %response_headers;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;

        if ($scope->{type} eq 'websocket') {
            # Reject by sending close without accept
            await $send->({
                type   => 'websocket.close',
                code   => 1008,
                reason => 'not allowed',
            });
        }
    };

    my ($conn, $stream_io, $client_sock, $server) = create_h2_connection(app => $app);

    my $client = create_client(
        on_header => sub {
            my ($sid, $name, $value) = @_;
            $response_headers{$name} = $value;
            return 0;
        },
    );

    complete_h2_handshake($client, $client_sock);
    # The app runs and rejects during open_ws_stream's exchange
    my $ws_stream_id = open_ws_stream($client, $client_sock);

    # Server should respond with 403 when rejecting before accept
    is($response_headers{':status'}, '403', 'Rejected WebSocket gets 403');

    $stream_io->close_now;
    $loop->remove($server);
};

done_testing;
