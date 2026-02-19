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
# Test: SSE Cleanup and Disconnect Handling over HTTP/2
# ============================================================
# Verifies that client disconnect, connection close, and stream
# close during SSE are handled cleanly without crashes.

use PAGI::Server::Connection;
use PAGI::Server;
use PAGI::Server::Protocol::HTTP1;
use PAGI::Server::Protocol::HTTP2;

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
# Client disconnect during SSE -> sse.disconnect
# ============================================================
subtest 'client disconnect during SSE delivers sse.disconnect' => sub {
    my $sse_started = 0;
    my $disconnect_event;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $receive->();

        await $send->({ type => 'sse.start', status => 200 });
        await $send->({ type => 'sse.send', data => 'hello' });
        $sse_started = 1;

        # Wait for disconnect
        my $event = await $receive->();
        $disconnect_event = $event;
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

    # Wait for SSE to start
    for (1..20) {
        $loop->loop_once(0.1);
        last if $sse_started;
    }

    # Close client side to simulate disconnect
    close($client_sock);

    # Let event loop process the disconnection
    for (1..10) {
        $loop->loop_once(0.1);
    }

    is($disconnect_event->{type}, 'sse.disconnect', 'Got sse.disconnect event');
    is($disconnect_event->{reason}, 'client_closed', 'Reason is client_closed');

    $stream_io->close_now;
    $loop->remove($server);
};

# ============================================================
# Connection close during SSE does not crash
# ============================================================
subtest 'connection close during SSE does not crash' => sub {
    my $sse_started = 0;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $receive->();

        await $send->({ type => 'sse.start', status => 200 });
        await $send->({ type => 'sse.send', data => 'first' });
        $sse_started = 1;

        # The connection will be closed by the test.
        # Subsequent sends should not crash.
        eval {
            await $send->({ type => 'sse.send', data => 'second' });
        };
        eval {
            await $send->({ type => 'sse.send', data => 'third' });
        };
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

    # Wait for SSE to start
    for (1..20) {
        $loop->loop_once(0.1);
        last if $sse_started;
    }

    # Close connection
    close($client_sock);

    # Let event loop process
    for (1..10) {
        $loop->loop_once(0.1);
    }

    pass('No crash on connection close during SSE');

    $stream_io->close_now;
    $loop->remove($server);
};

# ============================================================
# SSE with keepalive + disconnect: timers cleaned up
# ============================================================
subtest 'keepalive timers cleaned up on disconnect' => sub {
    my $sse_started = 0;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $receive->();

        await $send->({ type => 'sse.start', status => 200 });
        await $send->({
            type     => 'sse.keepalive',
            interval => 0.1,
            comment  => 'ka',
        });
        await $send->({ type => 'sse.send', data => 'with-keepalive' });
        $sse_started = 1;

        # Wait for disconnect
        await $receive->();
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

    # Wait for SSE to start with keepalive
    for (1..20) {
        $loop->loop_once(0.1);
        last if $sse_started;
    }

    # Let a few keepalive ticks fire
    exchange_frames($client, $client_sock, 5);

    # Close connection
    close($client_sock);

    # Let event loop process cleanup
    for (1..10) {
        $loop->loop_once(0.1);
    }

    # If we got here without a crash, timers were cleaned up properly
    pass('No crash after disconnect with active keepalive timer');

    $stream_io->close_now;
    $loop->remove($server);
};

done_testing;
