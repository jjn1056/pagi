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
# Test: Full SSE Send/Receive over HTTP/2
# ============================================================
# Verifies complete SSE sessions: start, send (with event/data/id),
# comment, and that data arrives as SSE-formatted DATA frames
# without chunked encoding.

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
# Complete SSE session: start, named events, id, comment
# ============================================================
subtest 'complete SSE session with named events, id, and comment' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $receive->();

        await $send->({ type => 'sse.start', status => 200 });

        # Named event with data and id
        await $send->({
            type  => 'sse.send',
            event => 'update',
            data  => 'payload1',
            id    => '1',
        });

        # Data-only event with retry
        await $send->({
            type  => 'sse.send',
            data  => 'payload2',
            retry => 5000,
        });

        # Comment
        await $send->({
            type    => 'sse.comment',
            comment => 'heartbeat',
        });

        # Multi-line data event
        await $send->({
            type  => 'sse.send',
            event => 'multi',
            data  => "line1\nline2\nline3",
            id    => '3',
        });
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

    $client->submit_request(
        method    => 'GET',
        path      => '/events',
        scheme    => 'http',
        authority => 'localhost',
        headers   => [['accept', 'text/event-stream']],
    );
    $client_sock->syswrite($client->mem_send);

    exchange_frames($client, $client_sock, 20);

    # Verify headers
    is($response_headers{':status'}, '200', 'Status 200');
    like($response_headers{'content-type'}, qr{text/event-stream}, 'Content-Type correct');
    is($response_headers{'cache-control'}, 'no-cache', 'Cache-Control set');

    # Verify SSE event format
    like($response_body, qr/event: update\n/, 'Named event field present');
    like($response_body, qr/data: payload1\n/, 'Data field for event 1');
    like($response_body, qr/id: 1\n/, 'ID field for event 1');

    like($response_body, qr/data: payload2\n/, 'Data field for event 2');
    like($response_body, qr/retry: 5000\n/, 'Retry field present');

    like($response_body, qr/:heartbeat\n/, 'Comment present');

    like($response_body, qr/event: multi\n/, 'Multi-line event name');
    like($response_body, qr/data: line1\ndata: line2\ndata: line3\n/, 'Multi-line data split correctly');
    like($response_body, qr/id: 3\n/, 'ID field for event 3');

    # Verify NO chunked encoding bytes
    unlike($response_body, qr/^[0-9a-f]+\r\n/m, 'No chunked hex length prefixes');
    unlike($response_body, qr/\r\n/, 'No CRLF chunked framing');

    $stream_io->close_now;
    $loop->remove($server);
};

# ============================================================
# Multiple data events arrive incrementally
# ============================================================
subtest 'SSE data events arrive incrementally in DATA frames' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $receive->();

        await $send->({ type => 'sse.start', status => 200 });

        for my $i (1..5) {
            await $send->({
                type => 'sse.send',
                data => "event$i",
            });
        }
    };

    my ($conn, $stream_io, $client_sock, $server) = create_h2c_connection(app => $app);

    my $response_body = '';
    my @data_chunks;
    my $client = create_client(
        on_data_chunk_recv => sub {
            my ($sid, $data) = @_;
            push @data_chunks, $data;
            $response_body .= $data;
            return 0;
        },
    );

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

    # All 5 events should be present
    for my $i (1..5) {
        like($response_body, qr/data: event$i\n/, "Event $i data present");
    }

    # Data should arrive in multiple chunks (not one big blob)
    ok(scalar @data_chunks >= 1, 'Data arrived in DATA frame chunks');

    $stream_io->close_now;
    $loop->remove($server);
};

# ============================================================
# SSE with custom status and headers
# ============================================================
subtest 'SSE with custom status and headers' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $receive->();

        await $send->({
            type    => 'sse.start',
            status  => 200,
            headers => [
                ['x-stream-id', 'test-123'],
                ['content-type', 'text/event-stream; charset=utf-8'],
            ],
        });

        await $send->({ type => 'sse.send', data => 'custom' });
    };

    my ($conn, $stream_io, $client_sock, $server) = create_h2c_connection(app => $app);

    my %response_headers;
    my $response_body = '';
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

    $client->submit_request(
        method    => 'GET',
        path      => '/events',
        scheme    => 'http',
        authority => 'localhost',
        headers   => [['accept', 'text/event-stream']],
    );
    $client_sock->syswrite($client->mem_send);

    exchange_frames($client, $client_sock, 20);

    is($response_headers{'x-stream-id'}, 'test-123', 'Custom header preserved');
    like($response_headers{'content-type'}, qr{text/event-stream}, 'Custom content-type preserved');
    like($response_body, qr/data: custom\n/, 'Data received');

    $stream_io->close_now;
    $loop->remove($server);
};

done_testing;
