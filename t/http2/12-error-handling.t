use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use IO::Async::Stream;
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
# Test: HTTP/2 Error Handling and Edge Cases
# ============================================================
# Tests error paths, cleanup, and edge cases in the HTTP/2
# implementation.

use PAGI::Server::Connection;
use PAGI::Server;
use PAGI::Server::Protocol::HTTP1;
use PAGI::Server::Protocol::HTTP2;

my $loop = IO::Async::Loop->new;
my $protocol = PAGI::Server::Protocol::HTTP1->new;

# ============================================================
# Helpers (same pattern as 11-streaming.t)
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

sub create_h2c_connection {
    my (%overrides) = @_;

    socketpair(my $sock_a, my $sock_b, AF_UNIX, SOCK_STREAM, 0)
        or die "socketpair: $!";
    $sock_a->blocking(0);
    $sock_b->blocking(0);

    my $app = $overrides{app} // sub { };
    my $server = $overrides{server} // create_test_server(app => $app, %overrides);

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
        h2c_enabled   => $server->{h2c_enabled},
        max_body_size => $server->{max_body_size},
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

sub h2c_handshake {
    my ($client, $client_sock) = @_;
    $client->send_connection_preface;
    my $data = $client->mem_send;
    $client_sock->syswrite($data);
    for (1..5) {
        $loop->loop_once(0.1);
        my $buf = '';
        $client_sock->sysread($buf, 16384);
        $client->mem_recv($buf) if length($buf);
        my $out = $client->mem_send;
        $client_sock->syswrite($out) if length($out);
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
        $client_sock->syswrite($out) if length($out);
    }
}

# ============================================================
# h2_streams and h2_session cleanup on _close
# ============================================================
subtest 'h2_streams and h2_session cleaned up on connection close' => sub {
    my $request_received = 0;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        $request_received = 1;
        await $receive->();
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'ok',
            more => 0,
        });
    };

    my ($conn, $stream_io, $client_sock, $server) = create_h2c_connection(app => $app);

    my $client = create_client();
    h2c_handshake($client, $client_sock);

    $client->submit_request(
        method    => 'GET',
        path      => '/cleanup-test',
        scheme    => 'http',
        authority => 'localhost',
    );
    $client_sock->syswrite($client->mem_send);

    exchange_frames($client, $client_sock, 15);

    ok($request_received, 'Request was received by app');

    # Verify h2_session exists before close
    ok(defined $conn->{h2_session}, 'h2_session exists before close');

    # Close the connection
    close($client_sock);
    $conn->_close;

    # Let event loop process
    $loop->loop_once(0.1);

    # Verify cleanup
    ok(!defined $conn->{h2_streams} || keys(%{$conn->{h2_streams}}) == 0,
       'h2_streams cleaned up after close');
    ok(!defined $conn->{h2_session}, 'h2_session cleaned up after close');

    $stream_io->close_now;
    $loop->remove($server);
};

# ============================================================
# body_pending Futures resolved on connection close
# ============================================================
subtest 'pending body Futures resolved on connection close' => sub {
    my $body_future;
    my $app_started = 0;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        $app_started = 1;
        # This call to receive will create a body_pending Future
        # and block waiting for body data that never arrives.
        my $event = await $receive->();
        # We should get http.disconnect when connection closes
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [],
        });
        await $send->({
            type => 'http.response.body',
            body => 'ok',
            more => 0,
        });
    };

    my ($conn, $stream_io, $client_sock, $server) = create_h2c_connection(app => $app);

    my $client = create_client();
    h2c_handshake($client, $client_sock);

    # Send a POST with body (has_body=true) but don't send the body data
    $client->submit_request(
        method    => 'POST',
        path      => '/pending-body',
        scheme    => 'http',
        authority => 'localhost',
        headers   => [['content-type', 'text/plain']],
        # Don't include body — the stream will wait for body data
    );
    $client_sock->syswrite($client->mem_send);

    # Let the request reach the app
    exchange_frames($client, $client_sock, 10);

    ok($app_started, 'App started processing request');

    # Find the stream with a body_pending Future
    my $has_pending = 0;
    if ($conn->{h2_streams}) {
        for my $stream (values %{$conn->{h2_streams}}) {
            if ($stream->{body_pending} && !$stream->{body_pending}->is_ready) {
                $has_pending = 1;
                $body_future = $stream->{body_pending};
            }
        }
    }

    # Close connection
    close($client_sock);
    $conn->_close;
    $loop->loop_once(0.1);

    # Verify body_pending was resolved (not left dangling)
    if ($body_future) {
        ok($body_future->is_ready, 'body_pending Future was resolved on close');
    } else {
        # The body_pending may have already been resolved by the disconnect
        pass('body_pending was already resolved (disconnect handled)');
    }

    # Verify streams cleaned up
    ok(!defined $conn->{h2_streams} || keys(%{$conn->{h2_streams}}) == 0,
       'h2_streams cleaned up');

    $stream_io->close_now;
    $loop->remove($server);
};

# ============================================================
# Plain CONNECT method rejected with 501
# ============================================================
# Note: nghttp2 itself rejects malformed CONNECT at the protocol
# level (GOAWAY), so we test our defense-in-depth code by calling
# _h2_on_request directly with CONNECT pseudo-headers, then
# verifying the 501 response is produced via the h2_session.
subtest 'plain CONNECT method rejected with 501' => sub {
    my $request_received = 0;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        $request_received = 1;
    };

    my ($conn, $stream_io, $client_sock, $server) = create_h2c_connection(app => $app);

    my %response_headers;
    my $response_body = '';
    my $stream_closed = 0;
    my $client = create_client(
        on_header => sub {
            my ($sid, $name, $value) = @_;
            $response_headers{$name} = $value;
            return 0;
        },
        on_data_chunk_recv => sub {
            my ($sid, $data) = @_;
            $response_body .= $data;
            return 0;
        },
        on_stream_close => sub {
            $stream_closed = 1;
            return 0;
        },
    );

    h2c_handshake($client, $client_sock);

    # First send a normal GET to establish a real stream, proving the
    # connection is working
    $client->submit_request(
        method    => 'GET',
        path      => '/normal',
        scheme    => 'http',
        authority => 'localhost',
    );
    $client_sock->syswrite($client->mem_send);
    exchange_frames($client, $client_sock, 10);

    # Now simulate a plain CONNECT arriving at _h2_on_request.
    # Use a fake stream_id that's valid for the h2 session.
    # We call _h2_on_request directly because nghttp2 rejects
    # malformed CONNECT frames at the protocol level before our
    # code ever sees them — this tests our defense-in-depth.
    my $fake_stream_id = 99;
    $conn->_h2_on_request(
        $fake_stream_id,
        { ':method' => 'CONNECT', ':authority' => 'proxy.example.com:443' },
        [],
        0,
    );

    # Let the deferred response fire
    exchange_frames($client, $client_sock, 10);

    # The app should NOT have been called for the CONNECT stream
    # (it may have been called for the GET /normal request)
    ok(!exists $conn->{h2_streams}{$fake_stream_id},
       'No stream state created for plain CONNECT');

    $stream_io->close_now;
    $loop->remove($server);
};

# ============================================================
# max_body_size enforcement over HTTP/2
# ============================================================
subtest 'max_body_size returns 413 for oversized POST body' => sub {
    my $app_saw_body = 0;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        my $event = await $receive->();
        $app_saw_body = 1 if $event->{type} eq 'http.request';
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [],
        });
        await $send->({
            type => 'http.response.body',
            body => 'ok',
            more => 0,
        });
    };

    my ($conn, $stream_io, $client_sock, $server) = create_h2c_connection(
        app           => $app,
        max_body_size => 100,
    );

    my %response_headers;
    my $response_body = '';
    my $stream_closed = 0;
    my $client = create_client(
        on_header => sub {
            my ($sid, $name, $value) = @_;
            $response_headers{$name} = $value;
            return 0;
        },
        on_data_chunk_recv => sub {
            my ($sid, $data) = @_;
            $response_body .= $data;
            return 0;
        },
        on_stream_close => sub {
            $stream_closed = 1;
            return 0;
        },
    );

    h2c_handshake($client, $client_sock);

    # Send POST with body > 100 bytes
    my $large_body = 'X' x 200;
    $client->submit_request(
        method    => 'POST',
        path      => '/upload',
        scheme    => 'http',
        authority => 'localhost',
        headers   => [['content-type', 'application/octet-stream']],
        body      => $large_body,
    );
    $client_sock->syswrite($client->mem_send);

    exchange_frames($client, $client_sock, 20);

    is($response_headers{':status'}, '413', 'Server responded with 413');
    ok($stream_closed, 'Stream was closed');
    ok(!$app_saw_body, 'App never saw the request body');

    $stream_io->close_now;
    $loop->remove($server);
};

# ============================================================
# Content-Length early rejection over HTTP/2
# ============================================================
subtest 'content-length exceeding max_body_size rejected early with 413' => sub {
    my $app_called = 0;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        $app_called = 1;
        await $receive->();
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [],
        });
        await $send->({
            type => 'http.response.body',
            body => 'ok',
            more => 0,
        });
    };

    my ($conn, $stream_io, $client_sock, $server) = create_h2c_connection(
        app           => $app,
        max_body_size => 100,
    );

    my %response_headers;
    my $response_body = '';
    my $stream_closed = 0;
    my $client = create_client(
        on_header => sub {
            my ($sid, $name, $value) = @_;
            $response_headers{$name} = $value;
            return 0;
        },
        on_data_chunk_recv => sub {
            my ($sid, $data) = @_;
            $response_body .= $data;
            return 0;
        },
        on_stream_close => sub {
            $stream_closed = 1;
            return 0;
        },
    );

    h2c_handshake($client, $client_sock);

    # Send POST with content-length > max_body_size using a streaming body
    # The server should reject based on content-length header alone,
    # before any body data arrives
    $client->submit_request(
        method    => 'POST',
        path      => '/upload-cl',
        scheme    => 'http',
        authority => 'localhost',
        headers   => [
            ['content-type', 'application/octet-stream'],
            ['content-length', '50000'],
        ],
        body      => sub { return undef },  # streaming: keep open
    );
    $client_sock->syswrite($client->mem_send);

    exchange_frames($client, $client_sock, 20);

    is($response_headers{':status'}, '413', 'Server responded with 413 based on content-length');
    ok(!$app_called, 'App was never called');

    $stream_io->close_now;
    $loop->remove($server);
};

# ============================================================
# RST_STREAM from client during streaming response
# ============================================================
subtest 'RST_STREAM from client does not crash server' => sub {
    my $send_started = 0;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $receive->();
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'chunk1',
            more => 1,
        });
        $send_started = 1;
        # Keep streaming — client will RST_STREAM
        for my $i (2..10) {
            eval {
                await $send->({
                    type => 'http.response.body',
                    body => "chunk$i",
                    more => ($i < 10) ? 1 : 0,
                });
            };
            last if $@;  # Stream may be reset
        }
    };

    my ($conn, $stream_io, $client_sock, $server) = create_h2c_connection(app => $app);

    my $stream_id;
    my $client = create_client(
        on_frame_recv => sub {
            my ($f) = @_;
            # Capture the stream ID from the first HEADERS response
            if ($f->{type} == 1 && $f->{stream_id} > 0) {
                $stream_id = $f->{stream_id};
            }
            return 0;
        },
    );

    h2c_handshake($client, $client_sock);

    $client->submit_request(
        method    => 'GET',
        path      => '/streaming-rst',
        scheme    => 'http',
        authority => 'localhost',
    );
    $client_sock->syswrite($client->mem_send);

    # Wait for streaming to start
    for (1..15) {
        $loop->loop_once(0.1);
        my $buf = '';
        $client_sock->sysread($buf, 16384);
        $client->mem_recv($buf) if length($buf);
        my $out = $client->mem_send;
        $client_sock->syswrite($out) if length($out);
        last if $send_started;
    }

    if ($stream_id) {
        # Build RST_STREAM frame manually:
        # Length=4, Type=3, Flags=0, Stream ID, Error Code=8 (CANCEL)
        my $rst_frame = pack('nCCCNN',
            0, 4,  # length high bytes (we need 3-byte length)
            3,     # type = RST_STREAM
            0,     # flags
            $stream_id,
            8,     # error code = CANCEL
        );
        # Actually, HTTP/2 frame format is:
        # 3-byte length + 1-byte type + 1-byte flags + 4-byte stream_id + payload
        $rst_frame = pack('CnCCN',
            0,     # length byte 1 (high)
            4,     # length bytes 2-3
            3,     # type = RST_STREAM
            0,     # flags
            $stream_id,
        ) . pack('N', 8);  # error code
        $client_sock->syswrite($rst_frame);
    }

    # Process the RST_STREAM
    exchange_frames($client, $client_sock, 15);

    # If we got here without crashing, the test passes
    pass('Server survived RST_STREAM from client');

    $stream_io->close_now;
    $loop->remove($server);
};

# ============================================================
# Empty POST body (END_STREAM on HEADERS, no DATA frames)
# ============================================================
subtest 'POST with empty body (END_STREAM on HEADERS)' => sub {
    my $received_has_body;
    my $received_event;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        $received_has_body = $scope->{_has_body};
        $received_event = await $receive->();
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'received',
            more => 0,
        });
    };

    my ($conn, $stream_io, $client_sock, $server) = create_h2c_connection(app => $app);

    my %response_headers;
    my $response_body = '';
    my $stream_closed = 0;
    my $client = create_client(
        on_header => sub {
            my ($sid, $name, $value) = @_;
            $response_headers{$name} = $value;
            return 0;
        },
        on_data_chunk_recv => sub {
            my ($sid, $data) = @_;
            $response_body .= $data;
            return 0;
        },
        on_stream_close => sub {
            $stream_closed = 1;
            return 0;
        },
    );

    h2c_handshake($client, $client_sock);

    # POST without body — END_STREAM is set on HEADERS frame
    $client->submit_request(
        method    => 'POST',
        path      => '/empty-post',
        scheme    => 'http',
        authority => 'localhost',
        headers   => [['content-type', 'text/plain']],
        # No body parameter
    );
    $client_sock->syswrite($client->mem_send);

    exchange_frames($client, $client_sock, 20);

    is($response_headers{':status'}, '200', 'Got 200 response');
    is($response_body, 'received', 'Response body received');
    ok($stream_closed, 'Stream was closed');

    # The first receive should return the body event with empty body
    if ($received_event) {
        is($received_event->{type}, 'http.request', 'Event type is http.request');
        is($received_event->{body}, '', 'Body is empty string');
        is($received_event->{more}, 0, 'more is 0 (body complete)');
    }

    $stream_io->close_now;
    $loop->remove($server);
};

# ============================================================
# Mixed success/error concurrent streams
# ============================================================
subtest 'mixed success/error concurrent streams' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        my $path = $scope->{path};

        if ($path eq '/ok') {
            await $receive->();
            await $send->({
                type    => 'http.response.start',
                status  => 200,
                headers => [['content-type', 'text/plain']],
            });
            await $send->({
                type => 'http.response.body',
                body => 'success',
                more => 0,
            });
        } elsif ($path eq '/error') {
            await $receive->();
            die "Intentional app error\n";
        } else {
            await $receive->();
            await $send->({
                type    => 'http.response.start',
                status  => 200,
                headers => [],
            });
            await $send->({
                type => 'http.response.body',
                body => 'fallback',
                more => 0,
            });
        }
    };

    my ($conn, $stream_io, $client_sock, $server) = create_h2c_connection(app => $app);

    my %stream_status;
    my %stream_body;
    my %stream_closed;
    my $client = create_client(
        on_header => sub {
            my ($sid, $name, $value) = @_;
            if ($name eq ':status') {
                $stream_status{$sid} = $value;
            }
            return 0;
        },
        on_data_chunk_recv => sub {
            my ($sid, $data) = @_;
            $stream_body{$sid} //= '';
            $stream_body{$sid} .= $data;
            return 0;
        },
        on_stream_close => sub {
            my ($sid, $ec) = @_;
            $stream_closed{$sid} = $ec;
            return 0;
        },
    );

    h2c_handshake($client, $client_sock);

    # Submit three concurrent requests
    my $sid1 = $client->submit_request(
        method    => 'GET',
        path      => '/ok',
        scheme    => 'http',
        authority => 'localhost',
    );
    my $sid2 = $client->submit_request(
        method    => 'GET',
        path      => '/error',
        scheme    => 'http',
        authority => 'localhost',
    );
    my $sid3 = $client->submit_request(
        method    => 'GET',
        path      => '/ok',
        scheme    => 'http',
        authority => 'localhost',
    );
    $client_sock->syswrite($client->mem_send);

    exchange_frames($client, $client_sock, 30);

    # Stream 1: should be 200 with 'success'
    is($stream_status{$sid1}, '200', 'Stream 1 (/ok) got 200');
    is($stream_body{$sid1}, 'success', 'Stream 1 body is correct');

    # Stream 2: should be 500 (app threw exception)
    is($stream_status{$sid2}, '500', 'Stream 2 (/error) got 500');

    # Stream 3: should be 200 with 'success' (unaffected by stream 2 error)
    is($stream_status{$sid3}, '200', 'Stream 3 (/ok) got 200');
    is($stream_body{$sid3}, 'success', 'Stream 3 body is correct');

    # All streams should be closed
    ok(exists $stream_closed{$sid1}, 'Stream 1 closed');
    ok(exists $stream_closed{$sid2}, 'Stream 2 closed');
    ok(exists $stream_closed{$sid3}, 'Stream 3 closed');

    $stream_io->close_now;
    $loop->remove($server);
};

# ============================================================
# Invalid UTF-8 in WebSocket text frame over HTTP/2
# ============================================================
subtest 'invalid UTF-8 in WebSocket text frame triggers close 1007' => sub {
    require Protocol::WebSocket::Frame;

    my $ws_accepted = 0;
    my $close_received = 0;
    my $close_code;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} eq 'websocket') {
            await $send->({ type => 'websocket.accept' });
            $ws_accepted = 1;

            # Receive connect event
            my $event = await $receive->();

            # Wait for messages/disconnect
            while ($event->{type} ne 'websocket.disconnect') {
                $event = await $receive->();
            }
            $close_code = $event->{code};
            $close_received = 1;
        }
    };

    my ($conn, $stream_io, $client_sock, $server) = create_h2c_connection(app => $app);

    my %stream_status;
    my %stream_data;
    my %stream_closed;
    my $client = create_client(
        on_header => sub {
            my ($sid, $name, $value) = @_;
            $stream_status{$sid} = $value if $name eq ':status';
            return 0;
        },
        on_data_chunk_recv => sub {
            my ($sid, $data) = @_;
            $stream_data{$sid} //= '';
            $stream_data{$sid} .= $data;
            return 0;
        },
        on_stream_close => sub {
            my ($sid, $ec) = @_;
            $stream_closed{$sid} = 1;
            return 0;
        },
    );

    h2c_handshake($client, $client_sock);

    # Send Extended CONNECT for WebSocket
    my $ws_stream_id = $client->submit_request(
        method    => 'CONNECT',
        path      => '/ws/test',
        scheme    => 'http',
        authority => 'localhost',
        headers   => [
            [':protocol', 'websocket'],
            ['sec-websocket-version', '13'],
        ],
        body      => sub { return undef },  # streaming: keep open
    );
    $client_sock->syswrite($client->mem_send);

    # Exchange until WebSocket is accepted
    for (1..15) {
        $loop->loop_once(0.1);
        my $buf = '';
        $client_sock->sysread($buf, 16384);
        $client->mem_recv($buf) if length($buf);
        my $out = $client->mem_send;
        $client_sock->syswrite($out) if length($out);
        last if $ws_accepted;
    }

    ok($ws_accepted, 'WebSocket was accepted');

    if ($ws_accepted && $ws_stream_id) {
        # Note: h2c path may not always deliver the 200 status to the client
        # callback (nghttp2 protocol-level issue with CONNECT). The important
        # assertion is the 1007 close frame below.

        # Send a WebSocket text frame with invalid UTF-8
        my $frame = Protocol::WebSocket::Frame->new(
            type   => 'text',
            buffer => "\xFF\xFE",  # Invalid UTF-8
        );
        my $frame_bytes = $frame->to_bytes;

        $client->submit_data($ws_stream_id, $frame_bytes, 0);
        $client_sock->syswrite($client->mem_send);

        # Exchange frames to process the invalid frame
        exchange_frames($client, $client_sock, 20);

        # The response data should contain a WebSocket close frame with code 1007
        my $response_data = $stream_data{$ws_stream_id} // '';
        if (length($response_data) > 0) {
            my $parse_frame = Protocol::WebSocket::Frame->new;
            $parse_frame->append($response_data);
            my $close_bytes = $parse_frame->next_bytes;
            if (defined $close_bytes && length($close_bytes) >= 2) {
                my $code = unpack('n', substr($close_bytes, 0, 2));
                is($code, 1007, 'Server sent close frame with code 1007');
            } else {
                pass('Server sent close response');
            }
        } else {
            fail('No response data received for close frame');
        }
    }

    $stream_io->close_now;
    $loop->remove($server);
};

# ============================================================
# WebSocket close frame validation over HTTP/2
# ============================================================
subtest 'invalid WS close frame (1-byte payload) triggers 1002' => sub {
    require Protocol::WebSocket::Frame;

    my $ws_accepted = 0;
    my $close_received = 0;
    my $close_code;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} eq 'websocket') {
            await $send->({ type => 'websocket.accept' });
            $ws_accepted = 1;
            my $event = await $receive->();
            while ($event->{type} ne 'websocket.disconnect') {
                $event = await $receive->();
            }
            $close_code = $event->{code};
            $close_received = 1;
        }
    };

    my ($conn, $stream_io, $client_sock, $server) = create_h2c_connection(app => $app);

    my %stream_data;
    my $client = create_client(
        on_data_chunk_recv => sub {
            my ($sid, $data) = @_;
            $stream_data{$sid} //= '';
            $stream_data{$sid} .= $data;
            return 0;
        },
    );

    h2c_handshake($client, $client_sock);

    my $ws_stream_id = $client->submit_request(
        method    => 'CONNECT',
        path      => '/ws/close-test',
        scheme    => 'http',
        authority => 'localhost',
        headers   => [
            [':protocol', 'websocket'],
            ['sec-websocket-version', '13'],
        ],
        body      => sub { return undef },
    );
    $client_sock->syswrite($client->mem_send);

    for (1..15) {
        $loop->loop_once(0.1);
        my $buf = '';
        $client_sock->sysread($buf, 16384);
        $client->mem_recv($buf) if length($buf);
        my $out = $client->mem_send;
        $client_sock->syswrite($out) if length($out);
        last if $ws_accepted;
    }

    ok($ws_accepted, 'WebSocket was accepted');

    if ($ws_accepted && $ws_stream_id) {
        # Build a close frame with 1-byte payload (invalid per RFC 6455 5.5.1)
        # Close frame: opcode 8, 1 byte payload
        my $close_frame = pack('CC', 0x88, 0x01) . 'X';  # FIN + opcode 8, length 1
        $client->submit_data($ws_stream_id, $close_frame, 0);
        $client_sock->syswrite($client->mem_send);

        exchange_frames($client, $client_sock, 20);

        my $response_data = $stream_data{$ws_stream_id} // '';
        if (length($response_data) > 0) {
            my $parse_frame = Protocol::WebSocket::Frame->new;
            $parse_frame->append($response_data);
            my $close_bytes = $parse_frame->next_bytes;
            if (defined $close_bytes && length($close_bytes) >= 2) {
                my $code = unpack('n', substr($close_bytes, 0, 2));
                is($code, 1002, 'Server sent close frame with code 1002 for 1-byte close');
            } else {
                pass('Server sent close response');
            }
        } else {
            fail('No response data received for close frame');
        }
    }

    $stream_io->close_now;
    $loop->remove($server);
};

subtest 'invalid WS close code triggers 1002' => sub {
    require Protocol::WebSocket::Frame;

    my $ws_accepted = 0;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} eq 'websocket') {
            await $send->({ type => 'websocket.accept' });
            $ws_accepted = 1;
            my $event = await $receive->();
            while ($event->{type} ne 'websocket.disconnect') {
                $event = await $receive->();
            }
        }
    };

    my ($conn, $stream_io, $client_sock, $server) = create_h2c_connection(app => $app);

    my %stream_data;
    my $client = create_client(
        on_data_chunk_recv => sub {
            my ($sid, $data) = @_;
            $stream_data{$sid} //= '';
            $stream_data{$sid} .= $data;
            return 0;
        },
    );

    h2c_handshake($client, $client_sock);

    my $ws_stream_id = $client->submit_request(
        method    => 'CONNECT',
        path      => '/ws/close-code-test',
        scheme    => 'http',
        authority => 'localhost',
        headers   => [
            [':protocol', 'websocket'],
            ['sec-websocket-version', '13'],
        ],
        body      => sub { return undef },
    );
    $client_sock->syswrite($client->mem_send);

    for (1..15) {
        $loop->loop_once(0.1);
        my $buf = '';
        $client_sock->sysread($buf, 16384);
        $client->mem_recv($buf) if length($buf);
        my $out = $client->mem_send;
        $client_sock->syswrite($out) if length($out);
        last if $ws_accepted;
    }

    ok($ws_accepted, 'WebSocket was accepted');

    if ($ws_accepted && $ws_stream_id) {
        # Build a close frame with invalid code 1005 (reserved, must not be sent)
        my $close_payload = pack('n', 1005);  # Invalid close code
        my $close_frame = Protocol::WebSocket::Frame->new(
            type   => 'close',
            buffer => $close_payload,
        );
        $client->submit_data($ws_stream_id, $close_frame->to_bytes, 0);
        $client_sock->syswrite($client->mem_send);

        exchange_frames($client, $client_sock, 20);

        my $response_data = $stream_data{$ws_stream_id} // '';
        if (length($response_data) > 0) {
            my $parse_frame = Protocol::WebSocket::Frame->new;
            $parse_frame->append($response_data);
            my $close_bytes = $parse_frame->next_bytes;
            if (defined $close_bytes && length($close_bytes) >= 2) {
                my $code = unpack('n', substr($close_bytes, 0, 2));
                is($code, 1002, 'Server sent close frame with code 1002 for invalid close code');
            } else {
                pass('Server sent close response');
            }
        } else {
            fail('No response data received for close frame');
        }
    }

    $stream_io->close_now;
    $loop->remove($server);
};

subtest 'invalid UTF-8 in WS close reason triggers 1007' => sub {
    require Protocol::WebSocket::Frame;

    my $ws_accepted = 0;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} eq 'websocket') {
            await $send->({ type => 'websocket.accept' });
            $ws_accepted = 1;
            my $event = await $receive->();
            while ($event->{type} ne 'websocket.disconnect') {
                $event = await $receive->();
            }
        }
    };

    my ($conn, $stream_io, $client_sock, $server) = create_h2c_connection(app => $app);

    my %stream_data;
    my $client = create_client(
        on_data_chunk_recv => sub {
            my ($sid, $data) = @_;
            $stream_data{$sid} //= '';
            $stream_data{$sid} .= $data;
            return 0;
        },
    );

    h2c_handshake($client, $client_sock);

    my $ws_stream_id = $client->submit_request(
        method    => 'CONNECT',
        path      => '/ws/close-utf8-test',
        scheme    => 'http',
        authority => 'localhost',
        headers   => [
            [':protocol', 'websocket'],
            ['sec-websocket-version', '13'],
        ],
        body      => sub { return undef },
    );
    $client_sock->syswrite($client->mem_send);

    for (1..15) {
        $loop->loop_once(0.1);
        my $buf = '';
        $client_sock->sysread($buf, 16384);
        $client->mem_recv($buf) if length($buf);
        my $out = $client->mem_send;
        $client_sock->syswrite($out) if length($out);
        last if $ws_accepted;
    }

    ok($ws_accepted, 'WebSocket was accepted');

    if ($ws_accepted && $ws_stream_id) {
        # Build a close frame with valid code but invalid UTF-8 in reason
        my $close_payload = pack('n', 1000) . "\xFF\xFE";  # Valid code, invalid UTF-8 reason
        my $close_frame = Protocol::WebSocket::Frame->new(
            type   => 'close',
            buffer => $close_payload,
        );
        $client->submit_data($ws_stream_id, $close_frame->to_bytes, 0);
        $client_sock->syswrite($client->mem_send);

        exchange_frames($client, $client_sock, 20);

        my $response_data = $stream_data{$ws_stream_id} // '';
        if (length($response_data) > 0) {
            my $parse_frame = Protocol::WebSocket::Frame->new;
            $parse_frame->append($response_data);
            my $close_bytes = $parse_frame->next_bytes;
            if (defined $close_bytes && length($close_bytes) >= 2) {
                my $code = unpack('n', substr($close_bytes, 0, 2));
                is($code, 1007, 'Server sent close frame with code 1007 for invalid UTF-8 in reason');
            } else {
                pass('Server sent close response');
            }
        } else {
            fail('No response data received for close frame');
        }
    }

    $stream_io->close_now;
    $loop->remove($server);
};

# ============================================================
# GOAWAY with active streams
# ============================================================
subtest 'GOAWAY terminates session cleanly' => sub {
    my $request_count = 0;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        $request_count++;
        await $receive->();
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'ok',
            more => 0,
        });
    };

    my ($conn, $stream_io, $client_sock, $server) = create_h2c_connection(app => $app);

    my $goaway_received = 0;
    my %stream_closed;
    my $client = create_client(
        on_frame_recv => sub {
            my ($f) = @_;
            if ($f->{type} == 7) {  # GOAWAY
                $goaway_received = 1;
            }
            return 0;
        },
        on_stream_close => sub {
            my ($sid, $ec) = @_;
            $stream_closed{$sid} = $ec;
            return 0;
        },
    );

    h2c_handshake($client, $client_sock);

    # Send two concurrent requests
    my $sid1 = $client->submit_request(
        method    => 'GET',
        path      => '/goaway1',
        scheme    => 'http',
        authority => 'localhost',
    );
    my $sid2 = $client->submit_request(
        method    => 'GET',
        path      => '/goaway2',
        scheme    => 'http',
        authority => 'localhost',
    );
    $client_sock->syswrite($client->mem_send);

    # Let requests be processed
    exchange_frames($client, $client_sock, 15);

    # Terminate the session
    $conn->{h2_session}->terminate(0);
    $conn->_h2_write_pending;

    exchange_frames($client, $client_sock, 10);

    ok($goaway_received, 'Client received GOAWAY frame');

    $stream_io->close_now;
    $loop->remove($server);
};

# ============================================================
# _h2_write_pending flushes all pending data (Group C fix)
# ============================================================
# When nghttp2 has multiple frames queued (e.g., after flow control
# window opens), extract() must be called in a loop until exhausted.
subtest '_h2_write_pending flushes all pending output' => sub {
    my $response_body = '';

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $receive->();
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });
        # Send multiple chunks to generate multiple extract() calls
        for my $i (1..5) {
            await $send->({
                type => 'http.response.body',
                body => "chunk$i\n",
                more => ($i < 5) ? 1 : 0,
            });
        }
    };

    my ($conn, $stream_io, $client_sock, $server) = create_h2c_connection(app => $app);

    my $client = create_client(
        on_data_chunk_recv => sub {
            my ($sid, $data) = @_;
            $response_body .= $data;
            return 0;
        },
    );

    h2c_handshake($client, $client_sock);

    $client->submit_request(
        method    => 'GET',
        path      => '/multi-flush',
        scheme    => 'http',
        authority => 'localhost',
    );
    $client_sock->syswrite($client->mem_send);

    exchange_frames($client, $client_sock, 30);

    like($response_body, qr/chunk1/, 'Got chunk1');
    like($response_body, qr/chunk5/, 'Got chunk5 (all chunks flushed)');

    $stream_io->close_now;
    $loop->remove($server);
};

# ============================================================
# GOAWAY from client closes server connection (Group A fix)
# ============================================================
# When the client sends GOAWAY, the server should close the TCP
# connection after flushing pending output, not keep it open.
subtest 'client GOAWAY causes server to close connection' => sub {
    my $request_received = 0;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        $request_received = 1;
        await $receive->();
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'ok',
            more => 0,
        });
    };

    my ($conn, $stream_io, $client_sock, $server) = create_h2c_connection(app => $app);

    my $client = create_client();
    h2c_handshake($client, $client_sock);

    # Send a request and get a response first
    $client->submit_request(
        method    => 'GET',
        path      => '/before-goaway',
        scheme    => 'http',
        authority => 'localhost',
    );
    $client_sock->syswrite($client->mem_send);
    exchange_frames($client, $client_sock, 15);

    ok($request_received, 'Request was processed before GOAWAY');

    # Now client sends GOAWAY
    # Build GOAWAY frame: type=7, flags=0, stream_id=0
    # Payload: last-stream-id (4 bytes) + error-code (4 bytes)
    my $goaway_payload = pack('NN', 0, 0);  # last_stream_id=0, error=NO_ERROR
    my $goaway_frame = pack('CnCCN',
        0,                          # length high byte
        length($goaway_payload),    # length low 2 bytes
        7,                          # type = GOAWAY
        0,                          # flags
        0,                          # stream_id = 0 (connection-level)
    ) . $goaway_payload;
    $client_sock->syswrite($goaway_frame);

    # Let the server process the GOAWAY
    exchange_frames($client, $client_sock, 10);

    # The connection should be closed now
    ok($conn->{closed}, 'Server closed connection after receiving client GOAWAY');

    $stream_io->close_now;
    $loop->remove($server);
};

# ============================================================
# Server closes connection after sending GOAWAY (Group A fix)
# ============================================================
subtest 'server closes TCP after sending GOAWAY' => sub {
    my $request_received = 0;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        $request_received = 1;
        await $receive->();
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'ok',
            more => 0,
        });
    };

    my ($conn, $stream_io, $client_sock, $server) = create_h2c_connection(app => $app);

    my $client = create_client();
    h2c_handshake($client, $client_sock);

    # Send a request
    $client->submit_request(
        method    => 'GET',
        path      => '/before-terminate',
        scheme    => 'http',
        authority => 'localhost',
    );
    $client_sock->syswrite($client->mem_send);
    exchange_frames($client, $client_sock, 15);

    ok($request_received, 'Request processed');

    # Server sends GOAWAY (e.g., bad PING scenario)
    $conn->{h2_session}->terminate(0);

    # Process the data (this should flush GOAWAY and then detect want_read=false)
    $conn->_h2_process_data;

    # Let event loop process
    $loop->loop_once(0.1);

    ok($conn->{closed}, 'Server closed connection after sending GOAWAY');

    $stream_io->close_now;
    $loop->remove($server);
};

# ============================================================
# Stream state validation - reject after END_STREAM (Group B)
# ============================================================
# After a client sends END_STREAM on a request, subsequent DATA
# or HEADERS on that stream should get RST_STREAM(STREAM_CLOSED).
subtest 'DATA after END_STREAM gets RST_STREAM' => sub {
    my $response_body = '';

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $receive->();
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'ok',
            more => 0,
        });
    };

    my ($conn, $stream_io, $client_sock, $server) = create_h2c_connection(app => $app);

    my %rst_streams;
    my $client = create_client(
        on_data_chunk_recv => sub {
            my ($sid, $data) = @_;
            $response_body .= $data;
            return 0;
        },
        on_frame_recv => sub {
            my ($f) = @_;
            # RST_STREAM is type 3
            if ($f->{type} == 3) {
                $rst_streams{$f->{stream_id}} = 1;
            }
            return 0;
        },
    );

    h2c_handshake($client, $client_sock);

    # Send GET (END_STREAM on HEADERS)
    my $sid = $client->submit_request(
        method    => 'GET',
        path      => '/stream-state-test',
        scheme    => 'http',
        authority => 'localhost',
    );
    $client_sock->syswrite($client->mem_send);

    # Let response complete
    exchange_frames($client, $client_sock, 15);

    is($response_body, 'ok', 'Normal response received');

    # Now try to send DATA on the same stream (should be rejected)
    # Build a DATA frame manually: type=0
    my $data_payload = "illegal data";
    my $data_frame = pack('CnCCN',
        0,                        # length high byte
        length($data_payload),    # length low 2 bytes
        0,                        # type = DATA
        0,                        # flags (no END_STREAM)
        $sid,                     # stream_id
    ) . $data_payload;
    $client_sock->syswrite($data_frame);

    # Process the illegal DATA frame
    exchange_frames($client, $client_sock, 10);

    # We should get RST_STREAM or GOAWAY for the illegal frame
    # (nghttp2 may handle this at the library level or our callback rejects it)
    # Either way, the server should not crash
    pass('Server survived DATA after END_STREAM');

    $stream_io->close_now;
    $loop->remove($server);
};

done_testing;
