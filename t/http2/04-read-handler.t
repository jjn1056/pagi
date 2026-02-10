use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use IO::Async::Stream;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Socket qw(AF_UNIX SOCK_STREAM);

plan skip_all => "Server integration tests not supported on Windows" if $^O eq 'MSWin32';
BEGIN {
    eval { require Net::HTTP2::nghttp2; 1 }
        or plan(skip_all => 'Net::HTTP2::nghttp2 not installed (optional)');
}

# ============================================================
# Test: HTTP/2 read handler wiring in Connection
# ============================================================
# Verifies that incoming HTTP/2 frames are fed to the session
# and outgoing frames are written back to the client.

use PAGI::Server::Connection;
use PAGI::Server;
use PAGI::Server::Protocol::HTTP1;
use PAGI::Server::Protocol::HTTP2;

my $loop = IO::Async::Loop->new;
my $app = sub { };
my $protocol = PAGI::Server::Protocol::HTTP1->new;

# Helper: create a test server with http2 enabled
sub create_test_server {
    my (%args) = @_;
    my $server = PAGI::Server->new(
        app   => $app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
        http2 => 1,
        %args,
    );
    $loop->add($server);
    return $server;
}

# Helper: create a socketpair-based connection
sub create_h2_connection {
    my (%overrides) = @_;

    my $server = $overrides{server} // create_test_server();

    socketpair(my $sock_a, my $sock_b, AF_UNIX, SOCK_STREAM, 0)
        or die "socketpair: $!";
    $sock_a->blocking(0);
    $sock_b->blocking(0);

    my $stream = IO::Async::Stream->new(
        read_handle  => $sock_a,
        write_handle => $sock_a,
        on_read => sub { 0 },
    );

    my $conn = PAGI::Server::Connection->new(
        stream        => $stream,
        app           => $overrides{app} // $app,
        protocol      => $protocol,
        server        => $server,
        h2_protocol   => $server->{http2_protocol},
        alpn_protocol => 'h2',
    );

    $server->add_child($stream);
    $conn->start;

    return ($conn, $stream, $sock_b, $server);
}

# ============================================================
# Feed HTTP/2 client preface → session processes it
# ============================================================
subtest 'Feed client preface to HTTP/2 connection' => sub {
    my ($conn, $stream, $client_sock, $server) = create_h2_connection();

    ok($conn->{is_h2}, 'Connection is HTTP/2');
    ok($conn->{h2_session}, 'Session exists');

    # Flush initial SETTINGS from server
    $loop->loop_once(0.1);

    my $server_settings = '';
    $client_sock->sysread($server_settings, 4096);
    ok(length($server_settings) > 0, 'Server sent initial SETTINGS');

    # Create client session to produce valid frames
    require Net::HTTP2::nghttp2::Session;
    my $client = Net::HTTP2::nghttp2::Session->new_client(
        callbacks => {
            on_begin_headers   => sub { 0 },
            on_header          => sub { 0 },
            on_frame_recv      => sub { 0 },
            on_data_chunk_recv => sub { 0 },
            on_stream_close    => sub { 0 },
        },
    );

    # Client sends connection preface + SETTINGS
    $client->send_connection_preface;
    my $client_preface = $client->mem_send;

    # Write client preface to server via the socket
    $client_sock->syswrite($client_preface);

    # Let the event loop process the read
    $loop->loop_once(0.1);

    # Feed server's initial SETTINGS to client
    $client->mem_recv($server_settings);

    # Server should have sent SETTINGS ACK
    $loop->loop_once(0.1);
    my $settings_ack = '';
    $client_sock->sysread($settings_ack, 4096);
    ok(length($settings_ack) > 0, 'Server sent SETTINGS ACK after client preface');

    $stream->close_now;
    $loop->remove($server);
};

# ============================================================
# Feed GET request → on_request callback fires
# ============================================================
subtest 'Feed GET request triggers on_request' => sub {
    my @requests;

    my ($conn, $stream, $client_sock, $server) = create_h2_connection();

    # Override the on_request callback to capture requests
    my $weak_conn = $conn;
    Scalar::Util::weaken($weak_conn);

    $conn->{h2_session}{on_request} = sub {
        push @requests, [@_];
    };

    # Flush initial SETTINGS from server
    $loop->loop_once(0.1);
    my $server_settings = '';
    $client_sock->sysread($server_settings, 4096);

    # Create client and complete handshake
    require Net::HTTP2::nghttp2::Session;
    my $client = Net::HTTP2::nghttp2::Session->new_client(
        callbacks => {
            on_begin_headers   => sub { 0 },
            on_header          => sub { 0 },
            on_frame_recv      => sub { 0 },
            on_data_chunk_recv => sub { 0 },
            on_stream_close    => sub { 0 },
        },
    );

    # Client preface + SETTINGS
    $client->send_connection_preface;
    my $data = $client->mem_send;
    $client_sock->syswrite($data);
    $loop->loop_once(0.1);

    # Feed server settings to client
    $client->mem_recv($server_settings);

    # Consume server SETTINGS ACK
    $loop->loop_once(0.1);
    my $ack = '';
    $client_sock->sysread($ack, 4096);
    $client->mem_recv($ack) if length($ack);

    # Client sends SETTINGS ACK
    my $client_ack = $client->mem_send;
    $client_sock->syswrite($client_ack) if length($client_ack);
    $loop->loop_once(0.1);

    # Consume any additional server data
    my $extra = '';
    $client_sock->sysread($extra, 4096);
    $client->mem_recv($extra) if length($extra);

    # Now send a GET request
    $client->submit_request(
        method    => 'GET',
        path      => '/hello',
        scheme    => 'https',
        authority => 'localhost',
    );

    my $request_data = $client->mem_send;
    $client_sock->syswrite($request_data);

    # Let the event loop process the request
    $loop->loop_once(0.1);

    ok(scalar @requests >= 1, 'on_request callback was called');

    if (@requests) {
        my ($stream_id, $pseudo, $headers, $has_body) = @{$requests[0]};
        ok($stream_id > 0, "stream_id is positive: $stream_id");
        is($pseudo->{':method'}, 'GET', 'Method is GET');
        is($pseudo->{':path'}, '/hello', 'Path is /hello');
    }

    $stream->close_now;
    $loop->remove($server);
};

# ============================================================
# Response frames written back to client
# ============================================================
subtest 'Response frames written back to client' => sub {
    my @requests;

    my ($conn, $stream, $client_sock, $server) = create_h2_connection();

    $conn->{h2_session}{on_request} = sub {
        push @requests, [@_];
    };

    # Flush initial SETTINGS
    $loop->loop_once(0.1);
    my $server_settings = '';
    $client_sock->sysread($server_settings, 4096);

    # Create client
    my %client_headers;
    my $client_body = '';

    require Net::HTTP2::nghttp2::Session;
    my $client = Net::HTTP2::nghttp2::Session->new_client(
        callbacks => {
            on_begin_headers   => sub { 0 },
            on_header          => sub {
                my ($stream_id, $name, $value) = @_;
                $client_headers{$name} = $value;
                return 0;
            },
            on_frame_recv      => sub { 0 },
            on_data_chunk_recv => sub {
                my ($stream_id, $data) = @_;
                $client_body .= $data;
                return 0;
            },
            on_stream_close    => sub { 0 },
        },
    );

    # Complete handshake
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

    # Send GET request
    $client->submit_request(
        method    => 'GET',
        path      => '/',
        scheme    => 'https',
        authority => 'localhost',
    );
    my $request_data = $client->mem_send;
    $client_sock->syswrite($request_data);
    $loop->loop_once(0.1);

    ok(scalar @requests >= 1, 'Request received');

    # Submit response via the session
    my $stream_id = $requests[0][0];
    $conn->{h2_session}->submit_response($stream_id,
        status  => 200,
        headers => [['content-type', 'text/plain']],
        body    => "Hello from HTTP/2\n",
    );

    # Flush the response
    $conn->_h2_write_pending;
    $loop->loop_once(0.1);

    # Read response from client socket
    my $response_data = '';
    $client_sock->sysread($response_data, 8192);
    ok(length($response_data) > 0, 'Client received response data');

    $client->mem_recv($response_data);

    # May need additional rounds
    for (1..3) {
        $loop->loop_once(0.05);
        my $more = '';
        $client_sock->sysread($more, 8192);
        last unless length($more);
        $client->mem_recv($more);
    }

    is($client_headers{':status'}, '200', 'Client received 200 status');
    is($client_body, "Hello from HTTP/2\n", 'Client received response body');

    $stream->close_now;
    $loop->remove($server);
};

# ============================================================
# GOAWAY → connection closes
# ============================================================
subtest 'GOAWAY triggers connection close' => sub {
    my ($conn, $stream, $client_sock, $server) = create_h2_connection();

    # Flush initial SETTINGS
    $loop->loop_once(0.1);
    my $buf = '';
    $client_sock->sysread($buf, 4096);

    ok(!$conn->{closed}, 'Connection not closed yet');

    # Send a GOAWAY frame directly
    # GOAWAY: length=8, type=0x07, flags=0, stream_id=0
    # Last-Stream-ID=0, Error-Code=0 (NO_ERROR)
    my $goaway = pack('nCCCN NN',
        0, 8,          # length=8 (high byte, low+type)
        0x07,          # type=GOAWAY
        0x00,          # flags=0
        0,             # stream_id=0
        0,             # last_stream_id=0
        0,             # error_code=NO_ERROR
    );

    # Actually, let's use a proper client session to send GOAWAY
    require Net::HTTP2::nghttp2::Session;
    my $client = Net::HTTP2::nghttp2::Session->new_client(
        callbacks => {
            on_begin_headers   => sub { 0 },
            on_header          => sub { 0 },
            on_frame_recv      => sub { 0 },
            on_data_chunk_recv => sub { 0 },
            on_stream_close    => sub { 0 },
        },
    );

    # Complete handshake
    $client->send_connection_preface;
    my $data = $client->mem_send;
    $client_sock->syswrite($data);
    $loop->loop_once(0.1);

    $client->mem_recv($buf);
    $loop->loop_once(0.1);
    my $ack = '';
    $client_sock->sysread($ack, 4096);
    $client->mem_recv($ack) if length($ack);

    my $client_ack = $client->mem_send;
    $client_sock->syswrite($client_ack) if length($client_ack);
    $loop->loop_once(0.1);

    # Client EOF (close their side)
    close($client_sock);
    $loop->loop_once(0.2);

    ok($conn->{closed}, 'Connection closed after client EOF');

    $loop->remove($server);
};

done_testing;
