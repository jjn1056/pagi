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
# Test: Cleartext HTTP/2 (h2c) via Client Preface Detection
# ============================================================
# Verifies that cleartext connections with an HTTP/2 client
# preface are detected and upgraded to HTTP/2 mode, while
# normal HTTP/1.1 connections on the same port continue to work.

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

    # No alpn_protocol — cleartext connection
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
# h2c preface detection upgrades cleartext to HTTP/2
# ============================================================
subtest 'h2c preface detected on cleartext connection' => sub {
    my @scopes;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        push @scopes, $scope;
        await $receive->();
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['x-proto', $scope->{http_version}]],
        });
        await $send->({
            type => 'http.response.body',
            body => "h2c works",
        });
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

    # Send HTTP/2 client preface + SETTINGS
    $client->send_connection_preface;
    my $data = $client->mem_send;
    $client_sock->syswrite($data);

    # Exchange SETTINGS
    for (1..5) {
        $loop->loop_once(0.1);
        my $buf = '';
        $client_sock->sysread($buf, 16384);
        $client->mem_recv($buf) if length($buf);
        my $out = $client->mem_send;
        $client_sock->syswrite($out) if length($out);
    }

    # Connection should now be in h2 mode
    ok($conn->{is_h2}, 'Connection upgraded to HTTP/2 via h2c preface');

    # Send GET request
    $client->submit_request(
        method    => 'GET',
        path      => '/h2c-test',
        scheme    => 'http',
        authority => 'localhost',
    );
    $client_sock->syswrite($client->mem_send);

    exchange_frames($client, $client_sock);

    is($response_headers{':status'}, '200', 'Got 200 via h2c');
    is($response_headers{'x-proto'}, '2', 'App sees http_version 2');
    is($response_body, 'h2c works', 'Response body correct');

    ok(scalar @scopes >= 1, 'App was called');
    if (@scopes) {
        is($scopes[0]{http_version}, '2', 'Scope has http_version 2');
        is($scopes[0]{scheme}, 'http', 'Scheme is http (cleartext)');
    }

    $stream_io->close_now;
    $loop->remove($server);
};

# ============================================================
# HTTP/1.1 on cleartext still works (no false h2c detection)
# ============================================================
subtest 'HTTP/1.1 cleartext not falsely detected as h2c' => sub {
    my @scopes;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        push @scopes, $scope;
        await $receive->();
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => "http/1.1",
        });
    };

    my ($conn, $stream_io, $client_sock, $server) = create_h2c_connection(app => $app);

    # Send a normal HTTP/1.1 request
    my $http_request = "GET /http1-test HTTP/1.1\r\nHost: localhost\r\n\r\n";
    $client_sock->syswrite($http_request);

    # Process the request
    for (1..10) {
        $loop->loop_once(0.1);
    }

    ok(!$conn->{is_h2}, 'Connection stays HTTP/1.1');

    # Read the response
    my $response = '';
    $client_sock->sysread($response, 16384);

    like($response, qr{HTTP/1\.1 200}, 'Got HTTP/1.1 200 response');
    like($response, qr{http/1\.1}, 'Response body is http/1.1');

    ok(scalar @scopes >= 1, 'App was called');
    if (@scopes) {
        is($scopes[0]{http_version}, '1.1', 'Scope has http_version 1.1');
    }

    $stream_io->close_now;
    $loop->remove($server);
};

# ============================================================
# h2c disabled (no http2 flag) stays HTTP/1.1
# ============================================================
subtest 'Without http2 flag, h2c preface treated as HTTP/1.1' => sub {
    socketpair(my $sock_a, my $sock_b, AF_UNIX, SOCK_STREAM, 0)
        or die "socketpair: $!";
    $sock_a->blocking(0);
    $sock_b->blocking(0);

    my $server = PAGI::Server->new(
        app   => sub { },
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
        # No http2 flag
    );
    $loop->add($server);

    my $stream = IO::Async::Stream->new(
        read_handle  => $sock_a,
        write_handle => $sock_a,
        on_read => sub { 0 },
    );

    my $conn = PAGI::Server::Connection->new(
        stream   => $stream,
        app      => sub { },
        protocol => $protocol,
        server   => $server,
        # No h2_protocol, no h2c_enabled
    );

    $server->add_child($stream);
    $conn->start;

    ok(!$conn->{h2c_enabled}, 'h2c not enabled without http2 flag');
    ok(!$conn->{is_h2}, 'Connection not HTTP/2');

    $stream->close_now;
    $loop->remove($server);
};

# ============================================================
# h2c with multiple requests on same connection
# ============================================================
subtest 'h2c supports multiplexed requests' => sub {
    my @paths;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        push @paths, $scope->{path};
        await $receive->();
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['x-path', $scope->{path}]],
        });
        await $send->({
            type => 'http.response.body',
            body => "path:$scope->{path}",
        });
    };

    my ($conn, $stream_io, $client_sock, $server) = create_h2c_connection(app => $app);

    my %response_data;
    my $client = create_client(
        on_data_chunk_recv => sub {
            my ($sid, $data) = @_;
            $response_data{$sid} //= '';
            $response_data{$sid} .= $data;
            return 0;
        },
    );

    # h2c handshake
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

    # Send two concurrent requests
    my $sid1 = $client->submit_request(
        method    => 'GET',
        path      => '/first',
        scheme    => 'http',
        authority => 'localhost',
    );
    my $sid2 = $client->submit_request(
        method    => 'GET',
        path      => '/second',
        scheme    => 'http',
        authority => 'localhost',
    );
    $client_sock->syswrite($client->mem_send);

    exchange_frames($client, $client_sock);

    ok($sid1 != $sid2, 'Two different stream IDs');
    is($response_data{$sid1}, 'path:/first', 'First request served');
    is($response_data{$sid2}, 'path:/second', 'Second request served');

    $stream_io->close_now;
    $loop->remove($server);
};

done_testing;
