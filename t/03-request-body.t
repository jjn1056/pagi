use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use Net::Async::HTTP;
use Future::AsyncAwait;

use PAGI::Server;

# Step 3: Request Body Handling
# Tests for examples/03-request-body/app.pl

my $loop = IO::Async::Loop->new;

# Load the example app
use FindBin qw($RealBin);
my $app_path = "$RealBin/../examples/03-request-body/app.pl";
my $example_app = do $app_path;
die "Failed to load $app_path: $@" if $@;
die "Failed to load $app_path: $!" unless defined $example_app;

# Test 1: POST body is received and echoed
subtest 'POST body is received and echoed' => sub {
    my $server = PAGI::Server->new(
        app   => $example_app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;

    my $http = Net::Async::HTTP->new;
    $loop->add($http);

    my $response = $http->POST(
        "http://127.0.0.1:$port/",
        'Hello World',
        content_type => 'text/plain',
    )->get;

    is($response->code, 200, 'Response status is 200');
    like($response->decoded_content, qr/You sent: Hello World/, 'Response contains echoed body');

    $server->shutdown->get;
    $loop->remove($server);
};

# Test 2: GET request without body receives "No body provided"
subtest 'GET request without body receives empty body event' => sub {
    my $server = PAGI::Server->new(
        app   => $example_app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;

    my $http = Net::Async::HTTP->new;
    $loop->add($http);

    my $response = $http->GET("http://127.0.0.1:$port/")->get;

    is($response->code, 200, 'Response status is 200');
    like($response->decoded_content, qr/No body provided/, 'Response says no body provided');

    $server->shutdown->get;
    $loop->remove($server);
};

# Test 3: Large POST body works correctly
subtest 'Large POST body works correctly' => sub {
    my $large_body = 'X' x 100_000;  # 100KB body

    my $received_body = '';
    my $event_count = 0;

    my $tracking_app = async sub  {
        my ($scope, $receive, $send) = @_;
        die "Unsupported: $scope->{type}" if $scope->{type} ne 'http';

        my $body = '';
        while (1) {
            my $event = await $receive->();
            last if $event->{type} ne 'http.request';
            $body .= $event->{body} // '';
            $event_count++;
            last unless $event->{more};
        }

        $received_body = $body;

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type => 'http.response.body',
            body => "Received " . length($body) . " bytes",
            more => 0,
        });
    };

    my $server = PAGI::Server->new(
        app   => $tracking_app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;

    my $http = Net::Async::HTTP->new;
    $loop->add($http);

    my $response = $http->POST(
        "http://127.0.0.1:$port/",
        $large_body,
        content_type => 'application/octet-stream',
    )->get;

    is($response->code, 200, 'Response status is 200');
    is(length($received_body), length($large_body), 'Full body was received');
    is($received_body, $large_body, 'Body content matches');
    # Large body may arrive in multiple events depending on network buffering
    ok($event_count >= 1, "At least 1 event received (got $event_count)");

    $server->shutdown->get;
    $loop->remove($server);
};

# Test 4: Chunked Transfer-Encoding on request body
subtest 'Chunked Transfer-Encoding on request body' => sub {
    my $received_body = '';

    my $echo_app = async sub  {
        my ($scope, $receive, $send) = @_;
        die "Unsupported: $scope->{type}" if $scope->{type} ne 'http';

        my $body = '';
        while (1) {
            my $event = await $receive->();
            last if $event->{type} ne 'http.request';
            $body .= $event->{body} // '';
            last unless $event->{more};
        }

        $received_body = $body;

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type => 'http.response.body',
            body => "Body: $body",
            more => 0,
        });
    };

    my $server = PAGI::Server->new(
        app   => $echo_app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;

    # Use raw socket to send chunked request
    require IO::Socket::INET;
    my $sock = IO::Socket::INET->new(
        PeerHost => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 5,
    );

    ok($sock, 'Connected to server');

    # Send chunked request
    my $request = "POST / HTTP/1.1\r\n";
    $request .= "Host: localhost\r\n";
    $request .= "Transfer-Encoding: chunked\r\n";
    $request .= "Content-Type: text/plain\r\n";
    $request .= "\r\n";
    # Chunk 1: "Hello"
    $request .= "5\r\nHello\r\n";
    # Chunk 2: " World"
    $request .= "6\r\n World\r\n";
    # Final chunk
    $request .= "0\r\n\r\n";

    print $sock $request;

    # Read response
    my $response = '';
    $sock->blocking(0);

    my $timeout = time + 5;
    while (time < $timeout) {
        $loop->loop_once(0.1);
        my $buf;
        my $n = $sock->sysread($buf, 4096);
        if (defined $n && $n > 0) {
            $response .= $buf;
        }
        last if $response =~ /\r\n\r\n/ && $response =~ /Body:/;
    }

    close($sock);

    like($response, qr/HTTP\/1\.1 200/, 'Response status is 200');
    is($received_body, 'Hello World', 'Chunked body was de-chunked correctly');

    $server->shutdown->get;
    $loop->remove($server);
};

done_testing;
