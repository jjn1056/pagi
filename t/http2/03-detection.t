use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use IO::Async::Stream;
use FindBin;
use lib "$FindBin::Bin/../../lib";

plan skip_all => "Server integration tests not supported on Windows" if $^O eq 'MSWin32';

# ============================================================
# Test: HTTP/2 detection and session initialization in Connection
# ============================================================

use PAGI::Server::Connection;
use PAGI::Server;
use PAGI::Server::Protocol::HTTP1;

my $loop = IO::Async::Loop->new;

my $app = sub { };
my $protocol = PAGI::Server::Protocol::HTTP1->new;

# Helper: create a mock stream (pipe-based) for testing
sub create_mock_stream {
    my ($rd, $wr) = IO::Async::Stream->new_pair(loop => $loop);
    return ($rd, $wr);
}

# Helper: create a Server instance to parent the Connection
sub create_test_server {
    my (%args) = @_;
    my $server = PAGI::Server->new(
        app   => $app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
        %args,
    );
    $loop->add($server);
    return $server;
}

# ============================================================
# Connection accepts alpn_protocol parameter
# ============================================================
subtest 'Connection accepts alpn_protocol parameter' => sub {
    my $server = create_test_server();

    # Create a pipe pair for testing
    my ($rd, $wr);
    pipe($rd, $wr) or die "pipe: $!";

    my $stream = IO::Async::Stream->new(
        read_handle => $rd,
        on_read => sub { 0 },
    );

    my $conn = PAGI::Server::Connection->new(
        stream       => $stream,
        app          => $app,
        protocol     => $protocol,
        server       => $server,
        alpn_protocol => 'h2',
    );

    is($conn->{alpn_protocol}, 'h2', 'alpn_protocol stored in connection');

    $loop->remove($server);
};

# ============================================================
# Connection accepts h2_protocol parameter
# ============================================================
subtest 'Connection accepts h2_protocol parameter' => sub {
    plan skip_all => "Net::HTTP2::nghttp2 not installed" unless PAGI::Server->has_http2;

    my $server = create_test_server(http2 => 1);

    my ($rd, $wr);
    pipe($rd, $wr) or die "pipe: $!";

    my $stream = IO::Async::Stream->new(
        read_handle => $rd,
        on_read => sub { 0 },
    );

    my $conn = PAGI::Server::Connection->new(
        stream       => $stream,
        app          => $app,
        protocol     => $protocol,
        server       => $server,
        h2_protocol  => $server->{http2_protocol},
        alpn_protocol => 'h2',
    );

    ok($conn->{h2_protocol}, 'h2_protocol stored in connection');
    isa_ok($conn->{h2_protocol}, 'PAGI::Server::Protocol::HTTP2');

    $loop->remove($server);
};

# ============================================================
# Connection with ALPN 'h2' initializes HTTP/2 session
# ============================================================
subtest 'ALPN h2 initializes HTTP/2 session' => sub {
    plan skip_all => "Net::HTTP2::nghttp2 not installed" unless PAGI::Server->has_http2;

    my $server = create_test_server(http2 => 1);

    my ($rd, $wr);
    pipe($rd, $wr) or die "pipe: $!";

    my $stream = IO::Async::Stream->new(
        read_handle  => $rd,
        write_handle => $wr,
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

    ok($conn->{is_h2}, 'Connection detected as HTTP/2');
    ok($conn->{h2_session}, 'HTTP/2 session created');
    isa_ok($conn->{h2_session}, 'PAGI::Server::Protocol::HTTP2::Session');

    $stream->close_now;
    $loop->remove($server);
};

# ============================================================
# Connection with ALPN 'http/1.1' stays HTTP/1.1
# ============================================================
subtest 'ALPN http/1.1 stays HTTP/1.1' => sub {
    plan skip_all => "Net::HTTP2::nghttp2 not installed" unless PAGI::Server->has_http2;

    my $server = create_test_server(http2 => 1);

    my ($rd, $wr);
    pipe($rd, $wr) or die "pipe: $!";

    my $stream = IO::Async::Stream->new(
        read_handle  => $rd,
        write_handle => $wr,
        on_read => sub { 0 },
    );

    my $conn = PAGI::Server::Connection->new(
        stream        => $stream,
        app           => $app,
        protocol      => $protocol,
        server        => $server,
        h2_protocol   => $server->{http2_protocol},
        alpn_protocol => 'http/1.1',
    );

    $server->add_child($stream);
    $conn->start;

    ok(!$conn->{is_h2}, 'Connection is not HTTP/2');
    ok(!$conn->{h2_session}, 'No HTTP/2 session created');

    $stream->close_now;
    $loop->remove($server);
};

# ============================================================
# Connection without ALPN stays HTTP/1.1 (default)
# ============================================================
subtest 'No ALPN stays HTTP/1.1' => sub {
    my $server = create_test_server();

    my ($rd, $wr);
    pipe($rd, $wr) or die "pipe: $!";

    my $stream = IO::Async::Stream->new(
        read_handle  => $rd,
        write_handle => $wr,
        on_read => sub { 0 },
    );

    my $conn = PAGI::Server::Connection->new(
        stream   => $stream,
        app      => $app,
        protocol => $protocol,
        server   => $server,
    );

    $server->add_child($stream);
    $conn->start;

    ok(!$conn->{is_h2}, 'Default connection is not HTTP/2');
    ok(!$conn->{h2_session}, 'No HTTP/2 session by default');

    $stream->close_now;
    $loop->remove($server);
};

# ============================================================
# HTTP/2 session sends initial SETTINGS on start
# ============================================================
subtest 'HTTP/2 session sends initial SETTINGS on start' => sub {
    plan skip_all => "Net::HTTP2::nghttp2 not installed" unless PAGI::Server->has_http2;

    my $server = create_test_server(http2 => 1);

    # Use socketpair for bidirectional I/O
    use Socket qw(AF_UNIX SOCK_STREAM);
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
        app           => $app,
        protocol      => $protocol,
        server        => $server,
        h2_protocol   => $server->{http2_protocol},
        alpn_protocol => 'h2',
    );

    $server->add_child($stream);
    $conn->start;

    ok($conn->{is_h2}, 'Connection is HTTP/2');

    # The initial SETTINGS should have been queued to write
    # Give the loop a moment to flush
    $loop->loop_once(0.1);

    # Read from the other end of the socket
    my $buf = '';
    $sock_b->sysread($buf, 4096);

    ok(length($buf) > 0, 'Server sent initial data (SETTINGS frame)');

    # HTTP/2 SETTINGS frame: 9-byte header, type=0x04
    if (length($buf) >= 9) {
        my ($len_hi, $len_lo, $type) = unpack('nCCC', $buf);
        my $frame_len = ($len_hi << 8) | $len_lo;
        is($type, 0x04, 'First frame is SETTINGS (type 0x04)');
    }

    $stream->close_now;
    $loop->remove($server);
};

done_testing;
