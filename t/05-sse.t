use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use Net::Async::HTTP;
use Future::AsyncAwait;
use FindBin;
use lib "$FindBin::Bin/../lib";

# Configure Future::IO for tests that use Future::IO->sleep()
eval { require Future::IO; 1 }
    or plan skip_all => 'Future::IO required for SSE tests';
Future::IO->load_impl('IOAsync');

use PAGI::Server;

plan skip_all => "Server integration tests not supported on Windows" if $^O eq 'MSWin32';

# Load example app
my $app_path = "$FindBin::Bin/../examples/05-sse-broadcaster/app.pl";
my $app = do $app_path;
die "Failed to load app from $app_path: $@" if $@;
die "App did not return coderef" unless ref $app eq 'CODE';

my $loop = IO::Async::Loop->new;

# Helper to create and start server
sub create_server {
    my ($test_app) = @_;
    $test_app //= $app;

    my $server = PAGI::Server->new(
        app              => $test_app,
        host             => '127.0.0.1',
        port             => 0,  # Random port
        quiet            => 1,
        shutdown_timeout => 1,  # Fast shutdown for tests
    );

    $loop->add($server);
    $server->listen->get;  # Wait for server to start

    return $server;
}

# Test 1: SSE response has correct Content-Type and events
subtest 'SSE broadcaster streams events' => sub {
    my $server = create_server();
    my $port = $server->port;

    # Use raw socket to capture SSE response
    use IO::Socket::INET;
    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 5,
    );

    SKIP: {
        skip "Cannot connect", 5 unless $sock;

        print $sock "GET / HTTP/1.1\r\n";
        print $sock "Host: 127.0.0.1:$port\r\n";
        print $sock "Accept: text/event-stream\r\n";
        print $sock "\r\n";

        # Read response - SSE uses chunked encoding
        $sock->blocking(0);
        my $response = '';
        my $deadline = time + 5;
        while (time < $deadline) {
            my $buf;
            my $n = sysread($sock, $buf, 4096);
            if (defined $n && $n > 0) {
                $response .= $buf;
            }
            $loop->loop_once(0.1);
            # Check if we got all expected events
            last if $response =~ /event: done/ && $response =~ /data: finished/;
        }
        close $sock;

        like($response, qr/HTTP\/1\.1 200/, 'SSE response is 200 OK');
        like($response, qr/content-type:\s*text\/event-stream/i, 'Content-Type is text/event-stream');
        like($response, qr/event: tick.*data: 1/s, 'First tick event received');
        like($response, qr/event: tick.*data: 2/s, 'Second tick event received');
        like($response, qr/event: done.*data: finished/s, 'Done event received');
    }

    $server->shutdown->get;
};

# Test 2: SSE scope type is 'sse'
subtest 'SSE scope type is sse' => sub {
    my $scope_type = '';

    my $test_app = async sub  {
        my ($scope, $receive, $send) = @_;
        # Handle lifespan scope
        if ($scope->{type} eq 'lifespan') {
            while (1) {
                my $event = await $receive->();
                if ($event->{type} eq 'lifespan.startup') {
                    await $send->({ type => 'lifespan.startup.complete' });
                }
                elsif ($event->{type} eq 'lifespan.shutdown') {
                    await $send->({ type => 'lifespan.shutdown.complete' });
                    last;
                }
            }
            return;
        }

        $scope_type = $scope->{type};

        await $send->({
            type    => 'sse.start',
            status  => 200,
            headers => [ [ 'content-type', 'text/event-stream' ] ],
        });

        await $send->({ type => 'sse.send', event => 'test', data => 'done' });
    };

    my $server = create_server($test_app);
    my $port = $server->port;

    # Use raw socket
    use IO::Socket::INET;
    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 5,
    );

    SKIP: {
        skip "Cannot connect", 1 unless $sock;

        print $sock "GET / HTTP/1.1\r\n";
        print $sock "Host: 127.0.0.1:$port\r\n";
        print $sock "Accept: text/event-stream\r\n";
        print $sock "\r\n";

        # Wait for response
        $sock->blocking(0);
        my $deadline = time + 3;
        while (time < $deadline) {
            $loop->loop_once(0.1);
        }
        close $sock;

        is($scope_type, 'sse', 'Scope type is sse');
    }

    $server->shutdown->get;
};

# Test 3: SSE multi-line data is formatted correctly
subtest 'SSE multi-line data formatting' => sub {
    my $test_app = async sub  {
        my ($scope, $receive, $send) = @_;
        die "Unsupported scope type: $scope->{type}" if $scope->{type} ne 'sse';

        await $send->({
            type    => 'sse.start',
            status  => 200,
            headers => [ [ 'content-type', 'text/event-stream' ] ],
        });

        await $send->({
            type  => 'sse.send',
            event => 'multiline',
            data  => "line1\nline2\nline3",
        });
    };

    my $server = create_server($test_app);
    my $port = $server->port;

    use IO::Socket::INET;
    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 5,
    );

    SKIP: {
        skip "Cannot connect", 1 unless $sock;

        print $sock "GET / HTTP/1.1\r\n";
        print $sock "Host: 127.0.0.1:$port\r\n";
        print $sock "Accept: text/event-stream\r\n";
        print $sock "\r\n";

        $sock->blocking(0);
        my $response = '';
        my $deadline = time + 3;
        while (time < $deadline) {
            my $buf;
            my $n = sysread($sock, $buf, 4096);
            if (defined $n && $n > 0) {
                $response .= $buf;
            }
            $loop->loop_once(0.1);
            last if $response =~ /data: line3/;
        }
        close $sock;

        # Multi-line data should be split into multiple data: lines
        like($response, qr/data: line1\ndata: line2\ndata: line3/, 'Multi-line data formatted correctly');
    }

    $server->shutdown->get;
};

# Test 4: SSE disconnect detection
subtest 'SSE disconnect detection' => sub {
    my $disconnect_received = 0;

    my $test_app = async sub  {
        my ($scope, $receive, $send) = @_;
        die "Unsupported scope type: $scope->{type}" if $scope->{type} ne 'sse';

        # Consume the initial sse.request event (body, even if empty for GET)
        my $req_event = await $receive->();
        # Should be sse.request with empty body for GET

        await $send->({
            type    => 'sse.start',
            status  => 200,
            headers => [ [ 'content-type', 'text/event-stream' ] ],
        });

        # Send one event
        await $send->({ type => 'sse.send', event => 'test', data => 'hello' });

        # Wait for disconnect
        my $event = await $receive->();
        if ($event->{type} eq 'sse.disconnect') {
            $disconnect_received = 1;
        }
    };

    my $server = create_server($test_app);
    my $port = $server->port;

    use IO::Socket::INET;
    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 5,
    );

    SKIP: {
        skip "Cannot connect", 1 unless $sock;

        print $sock "GET / HTTP/1.1\r\n";
        print $sock "Host: 127.0.0.1:$port\r\n";
        print $sock "Accept: text/event-stream\r\n";
        print $sock "\r\n";

        # Wait for event
        $sock->blocking(0);
        my $deadline = time + 2;
        while (time < $deadline) {
            $loop->loop_once(0.1);
        }

        # Close connection abruptly
        close $sock;

        # Wait for disconnect to be detected
        $deadline = time + 2;
        while (!$disconnect_received && time < $deadline) {
            $loop->loop_once(0.1);
        }

        ok($disconnect_received, 'SSE disconnect event received by app');
    }

    $server->shutdown->get;
};

# Test 5: SSE chunked encoding is properly terminated
subtest 'SSE chunked encoding properly terminated' => sub {
    my $test_app = async sub  {
        my ($scope, $receive, $send) = @_;
        die "Unsupported scope type: $scope->{type}" if $scope->{type} ne 'sse';

        await $send->({
            type    => 'sse.start',
            status  => 200,
            headers => [ [ 'content-type', 'text/event-stream' ] ],
        });

        await $send->({ type => 'sse.send', event => 'test', data => 'hello' });
        # App returns normally - server should send chunked terminator
    };

    my $server = create_server($test_app);
    my $port = $server->port;

    use IO::Socket::INET;
    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 5,
    );

    SKIP: {
        skip "Cannot connect", 2 unless $sock;

        print $sock "GET / HTTP/1.1\r\n";
        print $sock "Host: 127.0.0.1:$port\r\n";
        print $sock "Accept: text/event-stream\r\n";
        print $sock "\r\n";

        # Read until connection closes (server should close after sending terminator)
        $sock->blocking(0);
        my $response = '';
        my $deadline = time + 5;
        my $connection_closed = 0;
        while (time < $deadline) {
            my $buf;
            my $n = sysread($sock, $buf, 4096);
            if (defined $n && $n > 0) {
                $response .= $buf;
            }
            elsif (defined $n && $n == 0) {
                # EOF - connection closed cleanly
                $connection_closed = 1;
                last;
            }
            $loop->loop_once(0.1);
        }
        close $sock;

        # Verify chunked terminator is present (0\r\n\r\n)
        # The response uses chunked encoding, so final chunk should be "0\r\n\r\n"
        like($response, qr/0\r\n\r\n$/, 'Response ends with chunked terminator (0\\r\\n\\r\\n)');
        ok($connection_closed, 'Connection closed cleanly after chunked terminator');
    }

    $server->shutdown->get;
};

# Test 6: SSE id and retry fields
subtest 'SSE id and retry fields' => sub {
    my $test_app = async sub  {
        my ($scope, $receive, $send) = @_;
        die "Unsupported scope type: $scope->{type}" if $scope->{type} ne 'sse';

        await $send->({
            type    => 'sse.start',
            status  => 200,
            headers => [ [ 'content-type', 'text/event-stream' ] ],
        });

        await $send->({
            type  => 'sse.send',
            event => 'update',
            data  => 'test',
            id    => 'msg-123',
            retry => 5000,
        });
    };

    my $server = create_server($test_app);
    my $port = $server->port;

    use IO::Socket::INET;
    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 5,
    );

    SKIP: {
        skip "Cannot connect", 2 unless $sock;

        print $sock "GET / HTTP/1.1\r\n";
        print $sock "Host: 127.0.0.1:$port\r\n";
        print $sock "Accept: text/event-stream\r\n";
        print $sock "\r\n";

        $sock->blocking(0);
        my $response = '';
        my $deadline = time + 3;
        while (time < $deadline) {
            my $buf;
            my $n = sysread($sock, $buf, 4096);
            if (defined $n && $n > 0) {
                $response .= $buf;
            }
            $loop->loop_once(0.1);
            last if $response =~ /retry:/;
        }
        close $sock;

        like($response, qr/id: msg-123/, 'id field present');
        like($response, qr/retry: 5000/, 'retry field present');
    }

    $server->shutdown->get;
};

# Test 7: SSE with POST method (for htmx/datastar/fetch-event-source)
subtest 'SSE with POST method' => sub {
    my $scope_type = '';
    my $scope_method = '';
    my $body_received = '';

    my $test_app = async sub {
        my ($scope, $receive, $send) = @_;

        # Handle lifespan scope
        if ($scope->{type} eq 'lifespan') {
            while (1) {
                my $event = await $receive->();
                if ($event->{type} eq 'lifespan.startup') {
                    await $send->({ type => 'lifespan.startup.complete' });
                }
                elsif ($event->{type} eq 'lifespan.shutdown') {
                    await $send->({ type => 'lifespan.shutdown.complete' });
                    last;
                }
            }
            return;
        }

        $scope_type = $scope->{type};
        $scope_method = $scope->{method};

        # Read POST body (sse.request event, like http.request)
        my $event = await $receive->();
        if ($event->{type} eq 'sse.request') {
            $body_received = $event->{body} // '';
        }

        await $send->({
            type    => 'sse.start',
            status  => 200,
            headers => [ [ 'content-type', 'text/event-stream' ] ],
        });

        await $send->({ type => 'sse.send', event => 'echo', data => $body_received });
    };

    my $server = create_server($test_app);
    my $port = $server->port;

    use IO::Socket::INET;
    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 5,
    );

    SKIP: {
        skip "Cannot connect", 4 unless $sock;

        my $body = '{"query": "test data"}';
        my $body_len = length($body);

        print $sock "POST /stream HTTP/1.1\r\n";
        print $sock "Host: 127.0.0.1:$port\r\n";
        print $sock "Accept: text/event-stream\r\n";
        print $sock "Content-Type: application/json\r\n";
        print $sock "Content-Length: $body_len\r\n";
        print $sock "\r\n";
        print $sock $body;

        $sock->blocking(0);
        my $response = '';
        my $deadline = time + 3;
        while (time < $deadline) {
            my $buf;
            my $n = sysread($sock, $buf, 4096);
            if (defined $n && $n > 0) {
                $response .= $buf;
            }
            $loop->loop_once(0.1);
            last if $response =~ /event: echo/;
        }
        close $sock;

        is($scope_type, 'sse', 'POST request with Accept: text/event-stream gets sse scope');
        is($scope_method, 'POST', 'Method is preserved as POST');
        like($response, qr/HTTP\/1\.1 200/, 'SSE response is 200 OK');
        like($response, qr/data: \{"query": "test data"\}/, 'POST body echoed in SSE event');
    }

    $server->shutdown->get;
};

done_testing;
