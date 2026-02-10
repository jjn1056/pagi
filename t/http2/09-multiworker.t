use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use IO::Async::Stream;
use Future::AsyncAwait;
use FindBin;
use lib "$FindBin::Bin/../../lib";

plan skip_all => "Server integration tests not supported on Windows" if $^O eq 'MSWin32';
plan skip_all => "Fork not available on this platform" if $^O eq 'MSWin32';
BEGIN {
    eval { require Net::HTTP2::nghttp2; 1 }
        or plan(skip_all => 'Net::HTTP2::nghttp2 not installed (optional)');
}

# ============================================================
# Test: Multi-Worker HTTP/2 Support
# ============================================================
# Verifies that HTTP/2 configuration propagates correctly to
# worker processes in multi-worker mode.

use PAGI::Server;
use PAGI::Server::Protocol::HTTP2;

# ============================================================
# Multi-worker server stores http2 config
# ============================================================
subtest 'Multi-worker server with http2 enabled' => sub {
    my $loop = IO::Async::Loop->new;

    my $server = PAGI::Server->new(
        app     => sub { },
        host    => '127.0.0.1',
        port    => 0,
        workers => 2,
        http2   => 1,
        quiet   => 1,
    );
    $loop->add($server);

    ok($server->{http2}, 'http2 flag stored');
    ok($server->{http2_enabled}, 'http2_enabled set');
    ok($server->{http2_protocol}, 'http2_protocol created');
    is($server->{workers}, 2, 'workers set to 2');

    $loop->remove($server);
};

# ============================================================
# Worker inherits http2 config from parent
# ============================================================
subtest 'Worker server inherits http2 from parent' => sub {
    # Test that _run_as_worker creates a worker server with http2.
    # We can't easily test the forking path directly, but we can
    # verify that PAGI::Server->new with the same params the worker
    # would receive produces a correctly configured server.

    my $loop = IO::Async::Loop->new;

    # Parent server config
    my $parent = PAGI::Server->new(
        app     => sub { },
        host    => '127.0.0.1',
        port    => 0,
        workers => 2,
        http2   => 1,
        quiet   => 1,
    );
    $loop->add($parent);

    # Simulate what _run_as_worker does when creating a worker server
    my $worker = PAGI::Server->new(
        app             => $parent->{app},
        host            => $parent->{host},
        port            => $parent->{port},
        ssl             => $parent->{ssl},
        http2           => $parent->{http2},  # This must be passed
        quiet           => 1,
        workers         => 0,
    );
    $loop->add($worker);

    ok($worker->{http2_enabled}, 'Worker has http2_enabled');
    ok($worker->{http2_protocol}, 'Worker has http2_protocol');

    $loop->remove($worker);
    $loop->remove($parent);
};

# ============================================================
# Worker without http2 does not enable it
# ============================================================
subtest 'Worker without http2 stays HTTP/1.1 only' => sub {
    my $loop = IO::Async::Loop->new;

    my $server = PAGI::Server->new(
        app     => sub { },
        host    => '127.0.0.1',
        port    => 0,
        workers => 2,
        quiet   => 1,
    );
    $loop->add($server);

    ok(!$server->{http2_enabled}, 'http2 not enabled by default');
    ok(!$server->{http2_protocol}, 'No http2_protocol without http2');

    $loop->remove($server);
};

# ============================================================
# Forked worker HTTP/2 integration test
# ============================================================
subtest 'Forked worker serves HTTP/2 requests' => sub {
    plan skip_all => "IO::Async::SSL not installed" unless PAGI::Server->has_tls;

    my $cert_file = "$FindBin::Bin/../../t/certs/server.crt";
    my $key_file  = "$FindBin::Bin/../../t/certs/server.key";
    plan skip_all => "Test certs not found" unless -f $cert_file && -f $key_file;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} eq 'lifespan') {
            my $event = await $receive->();
            await $send->({ type => 'lifespan.startup.complete' })
                if $event->{type} eq 'lifespan.startup';
            $event = await $receive->();
            await $send->({ type => 'lifespan.shutdown.complete' })
                if $event && $event->{type} eq 'lifespan.shutdown';
            return;
        }
        await $receive->();
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['x-http-version', $scope->{http_version}]],
        });
        await $send->({
            type => 'http.response.body',
            body => "worker-h2:$scope->{http_version}",
        });
    };

    my $loop = IO::Async::Loop->new;

    my $server = PAGI::Server->new(
        app     => $app,
        host    => '127.0.0.1',
        port    => 0,
        workers => 2,
        http2   => 1,
        quiet   => 1,
        ssl     => {
            cert_file => $cert_file,
            key_file  => $key_file,
        },
    );
    $loop->add($server);

    # Start listening (binds port, forks workers)
    $server->listen->get;
    my $port = $server->port;
    ok($port > 0, "Server bound to port $port");

    # Give workers time to start
    $loop->loop_once(0.5);

    # Connect with TLS + ALPN
    require IO::Socket::IP;
    require IO::Async::SSL;
    require Net::HTTP2::nghttp2::Session;

    my $tcp_sock = IO::Socket::IP->new(
        PeerHost => '127.0.0.1',
        PeerPort => $port,
        Blocking => 0,
    ) or die "TCP connect: $!";

    my $client_stream = IO::Async::Stream->new(handle => $tcp_sock, on_read => sub { 0 });
    $loop->add($client_stream);

    my ($ssl_stream) = $loop->SSL_upgrade(
        handle             => $client_stream,
        SSL_verify_mode    => IO::Socket::SSL::SSL_VERIFY_NONE(),
        SSL_alpn_protocols => ['h2', 'http/1.1'],
    )->get;

    my $handle = $ssl_stream->read_handle // $ssl_stream->write_handle;
    my $alpn = $handle->alpn_selected // 'none';
    is($alpn, 'h2', 'Worker ALPN selected h2');

    my $ssl_sock = $ssl_stream->read_handle;
    $loop->remove($ssl_stream);

    my %response_headers;
    my $response_body = '';

    my $h2_client = Net::HTTP2::nghttp2::Session->new_client(
        callbacks => {
            on_begin_headers   => sub { 0 },
            on_header          => sub {
                my ($sid, $name, $value) = @_;
                $response_headers{$name} = $value;
                return 0;
            },
            on_frame_recv      => sub { 0 },
            on_data_chunk_recv => sub {
                my ($sid, $data) = @_;
                $response_body .= $data;
                return 0;
            },
            on_stream_close    => sub { 0 },
        },
    );

    # HTTP/2 handshake
    $h2_client->send_connection_preface;
    $ssl_sock->syswrite($h2_client->mem_send);

    for (1..5) {
        $loop->loop_once(0.1);
        my $buf = '';
        $ssl_sock->sysread($buf, 16384);
        $h2_client->mem_recv($buf) if length($buf);
        my $out = $h2_client->mem_send;
        $ssl_sock->syswrite($out) if length($out);
    }

    # Send GET request
    $h2_client->submit_request(
        method    => 'GET',
        path      => '/',
        scheme    => 'https',
        authority => "localhost:$port",
    );
    $ssl_sock->syswrite($h2_client->mem_send);

    for (1..10) {
        $loop->loop_once(0.1);
        my $buf = '';
        $ssl_sock->sysread($buf, 16384);
        $h2_client->mem_recv($buf) if length($buf);
        my $out = $h2_client->mem_send;
        $ssl_sock->syswrite($out) if length($out);
    }

    is($response_headers{':status'}, '200', 'Worker returned 200');
    is($response_headers{'x-http-version'}, '2', 'Worker reports HTTP/2');
    is($response_body, 'worker-h2:2', 'Worker response confirms HTTP/2');

    # Clean up: signal workers to stop and wait briefly
    $server->_initiate_multiworker_shutdown;
    $loop->loop_once(0.5);  # Let workers exit
    $loop->remove($server);
};

done_testing;
