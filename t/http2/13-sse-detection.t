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
# Test: SSE Detection over HTTP/2
# ============================================================
# Verifies that requests with Accept: text/event-stream header
# are detected as SSE and dispatched with type => 'sse' scope.

use PAGI::Server::Connection;
use PAGI::Server;
use PAGI::Server::Protocol::HTTP1;
use PAGI::Server::Protocol::HTTP2;

my $loop = IO::Async::Loop->new;
my $protocol = PAGI::Server::Protocol::HTTP1->new;

# ============================================================
# Helpers (same pattern as t/http2/11-streaming.t)
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
        h2c_enabled   => $server->{h2c_enabled},
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
# SSE detection: Accept: text/event-stream -> type => 'sse'
# ============================================================
subtest 'SSE request detected over HTTP/2' => sub {
    my $got_scope_type;
    my $got_http_version;
    my $got_path;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        $got_scope_type = $scope->{type};
        $got_http_version = $scope->{http_version};
        $got_path = $scope->{path};

        # Minimal SSE session: start then close
        await $send->({ type => 'sse.start', status => 200 });
        await $send->({ type => 'sse.send', data => 'hello' });
    };

    my ($conn, $stream_io, $client_sock, $server) = create_h2c_connection(app => $app);

    my $response_body = '';
    my %response_headers;
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
    );

    h2c_handshake($client, $client_sock);

    # Send request with Accept: text/event-stream
    $client->submit_request(
        method    => 'GET',
        path      => '/events',
        scheme    => 'http',
        authority => 'localhost',
        headers   => [['accept', 'text/event-stream']],
    );
    $client_sock->syswrite($client->mem_send);

    exchange_frames($client, $client_sock, 20);

    is($got_scope_type, 'sse', 'Scope type is sse');
    is($got_http_version, '2', 'HTTP version is 2');
    is($got_path, '/events', 'Path is correct');
    is($response_headers{':status'}, '200', 'Got 200 status');
    like($response_headers{'content-type'}, qr{text/event-stream}, 'Content-Type is text/event-stream');

    # Verify SSE data arrived (no chunked encoding framing)
    like($response_body, qr/data: hello/, 'SSE data received');
    unlike($response_body, qr/^[0-9a-f]+\r\n/m, 'No chunked encoding framing');

    $stream_io->close_now;
    $loop->remove($server);
};

# ============================================================
# Non-SSE request still gets type => 'http'
# ============================================================
subtest 'non-SSE request still gets http scope type' => sub {
    my $got_scope_type;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        $got_scope_type = $scope->{type};
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
        path      => '/normal',
        scheme    => 'http',
        authority => 'localhost',
    );
    $client_sock->syswrite($client->mem_send);

    exchange_frames($client, $client_sock, 20);

    is($got_scope_type, 'http', 'Non-SSE request gets http scope type');

    $stream_io->close_now;
    $loop->remove($server);
};

# ============================================================
# SSE receive returns sse.request
# ============================================================
subtest 'SSE receive returns sse.request' => sub {
    my $got_receive_type;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        my $event = await $receive->();
        $got_receive_type = $event->{type};

        await $send->({ type => 'sse.start', status => 200 });
        await $send->({ type => 'sse.send', data => 'test' });
    };

    my ($conn, $stream_io, $client_sock, $server) = create_h2c_connection(app => $app);

    my $client = create_client();
    h2c_handshake($client, $client_sock);

    $client->submit_request(
        method    => 'GET',
        path      => '/events',
        scheme    => 'http',
        authority => 'localhost',
        headers   => [['accept', 'text/event-stream']],
    );
    $client_sock->syswrite($client->mem_send);

    exchange_frames($client, $client_sock, 20);

    is($got_receive_type, 'sse.request', 'Receive returns sse.request event');

    $stream_io->close_now;
    $loop->remove($server);
};

done_testing;
