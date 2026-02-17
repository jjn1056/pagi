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
# Test: End-to-end HTTP/2 integration
# ============================================================
# Tests the full PAGI app lifecycle through HTTP/2 using
# socketpair connections (no TLS) and a real TLS+ALPN test
# using IO::Async::SSL within the same event loop.

use PAGI::Server::Connection;
use PAGI::Server;
use PAGI::Server::Protocol::HTTP1;
use PAGI::Server::Protocol::HTTP2;
use PAGI::Test::Client;
use Net::HTTP2::nghttp2::Session;

my $loop = IO::Async::Loop->new;
my $protocol = PAGI::Server::Protocol::HTTP1->new;

# ============================================================
# Helpers (reused from earlier tests)
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

# ============================================================
# Full lifecycle: GET with hello-http example app pattern
# ============================================================
subtest 'Full lifecycle: hello-http GET' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;

        if ($scope->{type} eq 'http') {
            await $receive->();  # Consume request

            await $send->({
                type    => 'http.response.start',
                status  => 200,
                headers => [
                    ['content-type', 'text/plain; charset=utf-8'],
                ],
            });
            await $send->({
                type => 'http.response.body',
                body => 'Hello, World!',
            });
        }
    };

    my ($conn, $stream, $client_sock, $server) = create_h2_connection(app => $app);

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

    complete_h2_handshake($client, $client_sock);

    $client->submit_request(
        method    => 'GET',
        path      => '/',
        scheme    => 'https',
        authority => 'localhost',
    );
    my $req_data = $client->mem_send;
    $client_sock->syswrite($req_data);

    read_response($client, $client_sock);

    is($response_headers{':status'}, '200', 'Got 200 status');
    is($response_headers{'content-type'}, 'text/plain; charset=utf-8', 'Got content-type');
    is($response_body, 'Hello, World!', 'Got correct body');
    ok($stream_closed, 'Stream was closed after response');

    $stream->close_now;
    $loop->remove($server);
};

# ============================================================
# Multiple sequential requests on same connection (keep-alive)
# ============================================================
subtest 'Sequential requests on same HTTP/2 connection' => sub {
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
            body => "request=$request_count path=$scope->{path}",
        });
    };

    my ($conn, $stream, $client_sock, $server) = create_h2_connection(app => $app);

    my %last_headers;
    my $last_body = '';

    my $client = create_client(
        on_header => sub {
            my ($sid, $name, $value) = @_;
            $last_headers{$name} = $value;
            return 0;
        },
        on_data_chunk_recv => sub {
            my ($sid, $data) = @_;
            $last_body .= $data;
            return 0;
        },
    );

    complete_h2_handshake($client, $client_sock);

    # First request
    $client->submit_request(
        method    => 'GET',
        path      => '/first',
        scheme    => 'https',
        authority => 'localhost',
    );
    $client_sock->syswrite($client->mem_send);
    read_response($client, $client_sock);

    is($last_headers{':status'}, '200', 'First request: 200');
    like($last_body, qr/request=1/, 'First request counted');
    like($last_body, qr{path=/first}, 'First request path');

    # Second request on same connection
    %last_headers = ();
    $last_body = '';

    $client->submit_request(
        method    => 'GET',
        path      => '/second',
        scheme    => 'https',
        authority => 'localhost',
    );
    $client_sock->syswrite($client->mem_send);
    read_response($client, $client_sock);

    is($last_headers{':status'}, '200', 'Second request: 200');
    like($last_body, qr/request=2/, 'Second request counted');
    like($last_body, qr{path=/second}, 'Second request path');

    is($request_count, 2, 'Both requests handled');

    $stream->close_now;
    $loop->remove($server);
};

# ============================================================
# Various HTTP methods
# ============================================================
subtest 'Various HTTP methods' => sub {
    my @methods_seen;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        push @methods_seen, $scope->{method};

        # Consume body
        while (1) {
            my $event = await $receive->();
            last if $event->{type} eq 'http.disconnect' || !($event->{more} // 0);
        }

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [],
        });
        await $send->({
            type => 'http.response.body',
            body => "method=$scope->{method}",
        });
    };

    my ($conn, $stream, $client_sock, $server) = create_h2_connection(app => $app);
    my $client = create_client();
    complete_h2_handshake($client, $client_sock);

    for my $method (qw(GET POST PUT DELETE PATCH)) {
        $client->submit_request(
            method    => $method,
            path      => '/test',
            scheme    => 'https',
            authority => 'localhost',
            ($method ne 'GET' && $method ne 'DELETE'
                ? (body => 'test')
                : ()),
        );
    }
    $client_sock->syswrite($client->mem_send);

    read_response($client, $client_sock, 15);

    is([sort @methods_seen], [sort qw(GET POST PUT DELETE PATCH)],
        'All HTTP methods handled');

    $stream->close_now;
    $loop->remove($server);
};

# ============================================================
# Error responses
# ============================================================
subtest 'App error returns 500' => sub {
    my $app = async sub {
        die "intentional test error";
    };

    my ($conn, $stream, $client_sock, $server) = create_h2_connection(app => $app);

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

    complete_h2_handshake($client, $client_sock);

    $client->submit_request(
        method    => 'GET',
        path      => '/',
        scheme    => 'https',
        authority => 'localhost',
    );
    $client_sock->syswrite($client->mem_send);

    # Capture warn output since the error handler uses warn
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    read_response($client, $client_sock);

    is($response_headers{':status'}, '500', 'Got 500 for app error');
    like($response_body, qr/Internal Server Error/, 'Error body present');
    ok(scalar(grep { /PAGI application error.*intentional test error/ } @warnings),
        'Error logged via warn');

    $stream->close_now;
    $loop->remove($server);
};

# ============================================================
# Test with PAGI::Test::Client for app-level HTTP/2 scope
# ============================================================
subtest 'PAGI::Test::Client validates app logic' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;

        if ($scope->{type} eq 'http') {
            await $receive->();

            await $send->({
                type    => 'http.response.start',
                status  => 200,
                headers => [['content-type', 'application/json']],
            });
            await $send->({
                type => 'http.response.body',
                body => '{"message":"hello"}',
            });
        }
    };

    my $client = PAGI::Test::Client->new(app => $app);

    my $res = $client->get('/api');
    is($res->status, 200, 'Test client: 200 status');
    is($res->json->{message}, 'hello', 'Test client: JSON body');
    is($res->content_type, 'application/json', 'Test client: content type');
};

# ============================================================
# TLS + ALPN test (async client within same event loop)
# ============================================================
subtest 'TLS + ALPN selects h2 (real server)' => sub {
    plan skip_all => "IO::Async::SSL not installed" unless PAGI::Server->has_tls;

    my $cert_file = "$FindBin::Bin/../../t/certs/server.crt";
    my $key_file  = "$FindBin::Bin/../../t/certs/server.key";
    plan skip_all => "Test certs not found" unless -f $cert_file && -f $key_file;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $receive->();
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['x-http-version', $scope->{http_version}]],
        });
        await $send->({ type => 'http.response.body', body => 'ok' });
    };

    my $server = PAGI::Server->new(
        app   => $app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
        http2 => 1,
        ssl   => {
            cert_file => $cert_file,
            key_file  => $key_file,
        },
    );

    $loop->add($server);
    $server->listen->get;
    my $port = $server->port;

    # Use IO::Async::SSL to connect asynchronously within the same
    # event loop. This lets both server and client share the loop,
    # so the TLS handshake completes naturally.
    require IO::Socket::IP;
    require IO::Async::SSL;

    my $tcp_sock = IO::Socket::IP->new(
        PeerHost => '127.0.0.1',
        PeerPort => $port,
        Blocking => 0,
    ) or die "TCP connect: $!";

    my $client_stream = IO::Async::Stream->new(handle => $tcp_sock, on_read => sub { 0 });
    $loop->add($client_stream);

    # Do async SSL handshake with ALPN
    my ($ssl_stream) = $loop->SSL_upgrade(
        handle          => $client_stream,
        SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
        SSL_alpn_protocols => ['h2', 'http/1.1'],
    )->get;

    # Check ALPN negotiation result
    my $handle = $ssl_stream->read_handle // $ssl_stream->write_handle;
    my $alpn = $handle->alpn_selected // 'none';
    is($alpn, 'h2', 'ALPN selected h2');

    # Remove the stream from the loop so we can use the raw SSL socket
    # directly for HTTP/2 framing without IO::Async buffering interference
    my $ssl_sock = $ssl_stream->read_handle;
    $loop->remove($ssl_stream);

    my %response_headers;
    my $response_body = '';

    my $h2_client = create_client(
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

    # HTTP/2 handshake over the TLS socket
    $h2_client->send_connection_preface;
    $ssl_sock->syswrite($h2_client->mem_send);

    # Exchange SETTINGS
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

    # Read response
    for (1..10) {
        $loop->loop_once(0.1);
        my $buf = '';
        $ssl_sock->sysread($buf, 16384);
        $h2_client->mem_recv($buf) if length($buf);
        my $out = $h2_client->mem_send;
        $ssl_sock->syswrite($out) if length($out);
    }

    is($response_headers{':status'}, '200', 'Got 200 over TLS HTTP/2');
    is($response_headers{'x-http-version'}, '2', 'Server reports HTTP/2');

    $ssl_sock->close;
    $server->shutdown->get;
    $loop->remove($server);
};

done_testing;
