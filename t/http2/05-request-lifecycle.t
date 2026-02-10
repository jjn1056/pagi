use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use IO::Async::Stream;
use Future;
use Future::AsyncAwait;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Socket qw(AF_UNIX SOCK_STREAM);
use Scalar::Util qw(weaken);

plan skip_all => "Server integration tests not supported on Windows" if $^O eq 'MSWin32';
BEGIN {
    eval { require Net::HTTP2::nghttp2; 1 }
        or plan(skip_all => 'Net::HTTP2::nghttp2 not installed (optional)');
}

# ============================================================
# Test: HTTP/2 request → PAGI lifecycle
# ============================================================
# Verifies that HTTP/2 streams map correctly to PAGI
# scope/receive/send lifecycle.

use PAGI::Server::Connection;
use PAGI::Server;
use PAGI::Server::Protocol::HTTP1;
use PAGI::Server::Protocol::HTTP2;

my $loop = IO::Async::Loop->new;
my $protocol = PAGI::Server::Protocol::HTTP1->new;

# Helper: create a test server
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

# Helper: create an HTTP/2 connection with socketpair
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

# Helper: create nghttp2 client session
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

# Helper: complete HTTP/2 handshake over socketpair via event loop
sub complete_h2_handshake {
    my ($client, $client_sock) = @_;

    # Read server's initial SETTINGS
    $loop->loop_once(0.1);
    my $server_settings = '';
    $client_sock->sysread($server_settings, 4096);

    # Client sends connection preface + SETTINGS
    $client->send_connection_preface;
    my $data = $client->mem_send;
    $client_sock->syswrite($data);
    $loop->loop_once(0.1);

    # Feed server settings to client
    $client->mem_recv($server_settings);

    # Server sends SETTINGS ACK
    $loop->loop_once(0.1);
    my $ack = '';
    $client_sock->sysread($ack, 4096);
    $client->mem_recv($ack) if length($ack);

    # Client sends SETTINGS ACK
    my $client_ack = $client->mem_send;
    $client_sock->syswrite($client_ack) if length($client_ack);
    $loop->loop_once(0.1);

    # Consume any remaining server data
    my $extra = '';
    $client_sock->sysread($extra, 4096);
    $client->mem_recv($extra) if length($extra);
}

# Helper: read all response data from client socket
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
# GET → app receives correct scope
# ============================================================
subtest 'GET request produces correct PAGI scope' => sub {
    my @scopes;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        push @scopes, $scope;

        # Consume the request body
        my $event = await $receive->();

        # Send response
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'ok',
        });
    };

    my ($conn, $stream, $client_sock, $server) = create_h2_connection(app => $app);
    my $client = create_client();
    complete_h2_handshake($client, $client_sock);

    # Send GET /hello
    $client->submit_request(
        method    => 'GET',
        path      => '/hello?foo=bar',
        scheme    => 'https',
        authority => 'localhost:5000',
    );
    my $req_data = $client->mem_send;
    $client_sock->syswrite($req_data);

    # Let the event loop process
    read_response($client, $client_sock);

    ok(scalar @scopes >= 1, 'App was called with scope');

    if (@scopes) {
        my $scope = $scopes[0];
        is($scope->{type}, 'http', 'scope type is http');
        is($scope->{method}, 'GET', 'method is GET');
        is($scope->{path}, '/hello', 'path is /hello');
        is($scope->{query_string}, 'foo=bar', 'query_string is foo=bar');
        is($scope->{scheme}, 'https', 'scheme is https');
        is($scope->{http_version}, '2', 'http_version is 2');
        ok(ref $scope->{headers} eq 'ARRAY', 'headers is array');
    }

    $stream->close_now;
    $loop->remove($server);
};

# ============================================================
# POST with body → app receives body via receive
# ============================================================
subtest 'POST with body delivers body via receive' => sub {
    my @received_events;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;

        # Read all body events
        while (1) {
            my $event = await $receive->();
            push @received_events, $event;
            last if $event->{type} eq 'http.disconnect' || !($event->{more} // 0);
        }

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'received',
        });
    };

    my ($conn, $stream, $client_sock, $server) = create_h2_connection(app => $app);
    my $client = create_client();
    complete_h2_handshake($client, $client_sock);

    my $body = "hello=world&foo=bar";
    $client->submit_request(
        method    => 'POST',
        path      => '/submit',
        scheme    => 'https',
        authority => 'localhost',
        headers   => [['content-type', 'application/x-www-form-urlencoded']],
        body      => $body,
    );
    my $req_data = $client->mem_send;
    $client_sock->syswrite($req_data);

    read_response($client, $client_sock);

    ok(scalar @received_events >= 1, 'Receive callback produced events');

    # Combine all body chunks
    my $total_body = join('', map { $_->{body} // '' } grep { $_->{type} eq 'http.request' } @received_events);
    is($total_body, $body, 'Received correct body data');

    # Last event should have more=0
    my @req_events = grep { $_->{type} eq 'http.request' } @received_events;
    if (@req_events) {
        ok(!$req_events[-1]{more}, 'Last body event has more=0');
    }

    $stream->close_now;
    $loop->remove($server);
};

# ============================================================
# App sends 200 → client gets HTTP/2 response
# ============================================================
subtest 'App 200 response reaches client' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;

        await $receive->();

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [
                ['content-type', 'text/plain'],
                ['x-custom', 'test-value'],
            ],
        });
        await $send->({
            type => 'http.response.body',
            body => "Hello, HTTP/2!\n",
        });
    };

    my ($conn, $stream, $client_sock, $server) = create_h2_connection(app => $app);

    my %response_headers;
    my $response_body = '';

    my $client = create_client(
        on_header => sub {
            my ($stream_id, $name, $value) = @_;
            $response_headers{$name} = $value;
            return 0;
        },
        on_data_chunk_recv => sub {
            my ($stream_id, $data) = @_;
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
    my $req_data = $client->mem_send;
    $client_sock->syswrite($req_data);

    read_response($client, $client_sock, 10);

    is($response_headers{':status'}, '200', 'Got 200 status');
    is($response_headers{'content-type'}, 'text/plain', 'Got content-type header');
    is($response_headers{'x-custom'}, 'test-value', 'Got custom header');
    is($response_body, "Hello, HTTP/2!\n", 'Got correct body');

    $stream->close_now;
    $loop->remove($server);
};

# ============================================================
# Pseudo-headers mapped correctly
# ============================================================
subtest 'Pseudo-headers mapped to scope fields' => sub {
    my @scopes;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        push @scopes, $scope;

        await $receive->();

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [],
        });
        await $send->({
            type => 'http.response.body',
            body => '',
        });
    };

    my ($conn, $stream, $client_sock, $server) = create_h2_connection(app => $app);
    my $client = create_client();
    complete_h2_handshake($client, $client_sock);

    # Send request with explicit authority and scheme
    $client->submit_request(
        method    => 'POST',
        path      => '/api/v2/users?page=1',
        scheme    => 'https',
        authority => 'example.com:8443',
        headers   => [
            ['content-type', 'application/json'],
            ['accept', 'application/json'],
        ],
        body      => '{}',
    );
    my $req_data = $client->mem_send;
    $client_sock->syswrite($req_data);

    read_response($client, $client_sock);

    ok(scalar @scopes >= 1, 'App was called');

    if (@scopes) {
        my $scope = $scopes[0];
        is($scope->{method}, 'POST', ':method mapped to method');
        is($scope->{path}, '/api/v2/users', ':path mapped to path (without query)');
        is($scope->{query_string}, 'page=1', 'query string extracted from :path');
        is($scope->{scheme}, 'https', ':scheme mapped to scheme');

        # Check headers include regular headers (not pseudo-headers)
        my %headers = map { $_->[0] => $_->[1] } @{$scope->{headers}};
        is($headers{'content-type'}, 'application/json', 'content-type header present');
        is($headers{'accept'}, 'application/json', 'accept header present');

        # Pseudo-headers should NOT appear in regular headers
        ok(!exists $headers{':method'}, ':method not in headers');
        ok(!exists $headers{':path'}, ':path not in headers');
    }

    $stream->close_now;
    $loop->remove($server);
};

# ============================================================
# Multiple concurrent streams → independent scopes
# ============================================================
subtest 'Multiple concurrent streams produce independent scopes' => sub {
    my @scopes;
    my @responses;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        push @scopes, $scope;

        await $receive->();

        my $path = $scope->{path};
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => "path=$path",
        });
    };

    my ($conn, $stream, $client_sock, $server) = create_h2_connection(app => $app);

    my %stream_bodies;

    my $client = create_client(
        on_data_chunk_recv => sub {
            my ($stream_id, $data) = @_;
            $stream_bodies{$stream_id} //= '';
            $stream_bodies{$stream_id} .= $data;
            return 0;
        },
    );

    complete_h2_handshake($client, $client_sock);

    # Send two concurrent requests
    $client->submit_request(
        method    => 'GET',
        path      => '/first',
        scheme    => 'https',
        authority => 'localhost',
    );
    $client->submit_request(
        method    => 'GET',
        path      => '/second',
        scheme    => 'https',
        authority => 'localhost',
    );

    my $req_data = $client->mem_send;
    $client_sock->syswrite($req_data);

    # Give enough time for both to process
    read_response($client, $client_sock, 10);

    ok(scalar @scopes >= 2, 'Both requests created scopes');

    # Each stream should have its own response
    my @bodies = values %stream_bodies;
    my @sorted_bodies = sort @bodies;
    is(scalar @sorted_bodies, 2, 'Two streams got responses');
    is($sorted_bodies[0], 'path=/first', 'First stream got /first');
    is($sorted_bodies[1], 'path=/second', 'Second stream got /second');

    $stream->close_now;
    $loop->remove($server);
};

done_testing;
