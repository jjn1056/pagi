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
    eval { require Net::HTTP2::nghttp2; 1 }
        or plan(skip_all => 'Net::HTTP2::nghttp2 not installed (optional)');
}

# ============================================================
# Test: HTTP/2 Streaming Responses
# ============================================================
# Verifies that HTTP/2 streaming responses (more => 1) send
# DATA frames incrementally rather than accumulating in memory.

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
# Basic streaming: 3 chunks + final
# ============================================================
subtest 'basic streaming response delivers all data' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $receive->();
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });
        for my $i (1..3) {
            await $send->({
                type => 'http.response.body',
                body => "chunk$i",
                more => 1,
            });
        }
        await $send->({
            type => 'http.response.body',
            body => 'final',
            more => 0,
        });
    };

    my ($conn, $stream_io, $client_sock, $server) = create_h2c_connection(app => $app);

    my $response_body = '';
    my $stream_closed = 0;
    my $client = create_client(
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

    $client->submit_request(
        method    => 'GET',
        path      => '/streaming',
        scheme    => 'http',
        authority => 'localhost',
    );
    $client_sock->syswrite($client->mem_send);

    exchange_frames($client, $client_sock, 20);

    is($response_body, 'chunk1chunk2chunk3final', 'All streaming chunks received');
    ok($stream_closed, 'Stream was closed');

    $stream_io->close_now;
    $loop->remove($server);
};

# ============================================================
# Incremental delivery: data arrives before more => 0
# ============================================================
# This is the KEY test that proves the bug. With the old code,
# data only arrives after more => 0 because everything is
# accumulated in $body_chunks. With the fix, data arrives
# incrementally.
subtest 'streaming data arrives incrementally (not buffered until EOF)' => sub {
    # Use futures to coordinate: app waits for client to confirm
    # receipt of each chunk before sending the next one.
    my @chunk_received_at;  # Track when each data callback fires

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $receive->();
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        # Send chunk 1
        await $send->({
            type => 'http.response.body',
            body => 'AAA',
            more => 1,
        });

        # Send chunk 2
        await $send->({
            type => 'http.response.body',
            body => 'BBB',
            more => 1,
        });

        # Final
        await $send->({
            type => 'http.response.body',
            body => 'CCC',
            more => 0,
        });
    };

    my ($conn, $stream_io, $client_sock, $server) = create_h2c_connection(app => $app);

    my $response_body = '';
    my @data_events;  # Track each on_data_chunk_recv call separately
    my $client = create_client(
        on_data_chunk_recv => sub {
            my ($sid, $data) = @_;
            push @data_events, $data;
            $response_body .= $data;
            return 0;
        },
    );

    h2c_handshake($client, $client_sock);

    $client->submit_request(
        method    => 'GET',
        path      => '/incremental',
        scheme    => 'http',
        authority => 'localhost',
    );
    $client_sock->syswrite($client->mem_send);

    exchange_frames($client, $client_sock, 20);

    is($response_body, 'AAABBBCCC', 'All data received');

    # The key assertion: data should arrive in multiple on_data_chunk_recv
    # callbacks, not a single one. With the bug (accumulation), all data
    # arrives as one 'AAABBBCCC' chunk. With the fix, we get separate chunks.
    ok(scalar @data_events > 1,
        'Data arrived in multiple chunks (not accumulated)')
        or diag "Got " . scalar(@data_events) . " data events: " .
                join(', ', map { "'$_'" } @data_events);

    $stream_io->close_now;
    $loop->remove($server);
};

# ============================================================
# Empty final chunk: streaming + empty more => 0
# ============================================================
subtest 'streaming with empty final chunk' => sub {
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
            body => 'only-chunk',
            more => 1,
        });
        # Final chunk with empty body
        await $send->({
            type => 'http.response.body',
            body => '',
            more => 0,
        });
    };

    my ($conn, $stream_io, $client_sock, $server) = create_h2c_connection(app => $app);

    my $response_body = '';
    my $stream_closed = 0;
    my $client = create_client(
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

    $client->submit_request(
        method    => 'GET',
        path      => '/empty-final',
        scheme    => 'http',
        authority => 'localhost',
    );
    $client_sock->syswrite($client->mem_send);

    exchange_frames($client, $client_sock, 20);

    is($response_body, 'only-chunk', 'Body is just the streaming chunk');
    ok($stream_closed, 'Stream was closed');

    $stream_io->close_now;
    $loop->remove($server);
};

# ============================================================
# Backpressure: many large chunks don't cause unbounded growth
# ============================================================
subtest 'streaming with many chunks completes without accumulation' => sub {
    my $chunk_count = 50;
    my $chunk_size  = 8192;
    my $chunk_data  = 'X' x $chunk_size;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $receive->();
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'application/octet-stream']],
        });
        for my $i (1..$chunk_count) {
            await $send->({
                type => 'http.response.body',
                body => $chunk_data,
                more => ($i < $chunk_count) ? 1 : 0,
            });
        }
    };

    my ($conn, $stream_io, $client_sock, $server) = create_h2c_connection(app => $app);

    my $received_bytes = 0;
    my $stream_closed = 0;
    my $client = create_client(
        on_data_chunk_recv => sub {
            my ($sid, $data) = @_;
            $received_bytes += length($data);
            return 0;
        },
        on_stream_close => sub {
            $stream_closed = 1;
            return 0;
        },
    );

    h2c_handshake($client, $client_sock);

    $client->submit_request(
        method    => 'GET',
        path      => '/large-streaming',
        scheme    => 'http',
        authority => 'localhost',
    );
    $client_sock->syswrite($client->mem_send);

    # Many rounds needed: 50 x 8KB = 400KB, flow control window is 65535
    exchange_frames($client, $client_sock, 100);

    is($received_bytes, $chunk_count * $chunk_size,
        'All streaming data received');
    ok($stream_closed, 'Stream was closed');

    $stream_io->close_now;
    $loop->remove($server);
};

# ============================================================
# Single-shot (non-streaming): more => 0 as first body event
# ============================================================
subtest 'non-streaming response (more => 0 only) still works' => sub {
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
            body => 'single-shot',
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

    $client->submit_request(
        method    => 'GET',
        path      => '/single-shot',
        scheme    => 'http',
        authority => 'localhost',
    );
    $client_sock->syswrite($client->mem_send);

    exchange_frames($client, $client_sock, 20);

    is($response_headers{':status'}, '200', 'Got 200 status');
    is($response_body, 'single-shot', 'Body received correctly');
    ok($stream_closed, 'Stream was closed');

    $stream_io->close_now;
    $loop->remove($server);
};

# ============================================================
# Connection close during streaming: no crashes
# ============================================================
subtest 'connection close during streaming does not crash' => sub {
    my $send_started = 0;
    my $send_error = 0;

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
            body => 'first',
            more => 1,
        });
        $send_started = 1;

        # The connection will be closed here by the test.
        # Subsequent sends should not crash — they should just return.
        eval {
            await $send->({
                type => 'http.response.body',
                body => 'second',
                more => 1,
            });
        };
        # It's OK if it silently returns (connection closed check)
        eval {
            await $send->({
                type => 'http.response.body',
                body => 'final',
                more => 0,
            });
        };
    };

    my ($conn, $stream_io, $client_sock, $server) = create_h2c_connection(app => $app);

    my $client = create_client();

    h2c_handshake($client, $client_sock);

    $client->submit_request(
        method    => 'GET',
        path      => '/close-during-stream',
        scheme    => 'http',
        authority => 'localhost',
    );
    $client_sock->syswrite($client->mem_send);

    # Process until the app has sent the first chunk
    for (1..20) {
        $loop->loop_once(0.1);
        last if $send_started;
    }

    # Close the client side to simulate disconnect
    close($client_sock);

    # Let the event loop process the disconnection
    for (1..10) {
        $loop->loop_once(0.1);
    }

    # If we got here without crashing, the test passes
    pass('No crash on connection close during streaming');

    $stream_io->close_now;
    $loop->remove($server);
};

# ============================================================
# EOF race: empty final body with eof_pending
# ============================================================
# Regression: if data_callback is called when @data_queue is
# empty but $eof_pending is true, it should return ('', 1)
# to signal EOF, not undef (defer).
subtest 'EOF signaling when data_callback invoked after queue drained' => sub {
    # App sends streaming chunks, then final empty body (more => 0).
    # The key scenario: the sentinel empty string in @data_queue
    # gets consumed, then data_callback is called again.
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
            body => 'data',
            more => 1,
        });
        # Final chunk: empty body with more => 0
        await $send->({
            type => 'http.response.body',
            body => '',
            more => 0,
        });
    };

    my ($conn, $stream_io, $client_sock, $server) = create_h2c_connection(app => $app);

    my $response_body = '';
    my $stream_closed = 0;
    my $client = create_client(
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

    $client->submit_request(
        method    => 'GET',
        path      => '/eof-race',
        scheme    => 'http',
        authority => 'localhost',
    );
    $client_sock->syswrite($client->mem_send);

    # Give enough rounds to ensure EOF is signaled
    exchange_frames($client, $client_sock, 30);

    is($response_body, 'data', 'All data received');
    ok($stream_closed, 'Stream was closed (EOF properly signaled)');

    $stream_io->close_now;
    $loop->remove($server);
};

done_testing;
