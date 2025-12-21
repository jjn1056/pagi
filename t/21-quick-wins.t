use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use IO::Socket::INET;
use Future::AsyncAwait;
use FindBin;
use lib "$FindBin::Bin/../lib";

use PAGI::Server;
use PAGI::Server::Protocol::HTTP1;

my $loop = IO::Async::Loop->new;

# =============================================================================
# Test 3.16: Request Line Length Limit
# =============================================================================

subtest 'Request line length limit (3.16)' => sub {
    # Test the protocol parser directly
    my $protocol = PAGI::Server::Protocol::HTTP1->new(
        max_request_line_size => 100,  # Very small for testing
    );

    # Short request line should work
    my $short_request = "GET /short HTTP/1.1\r\nHost: localhost\r\n\r\n";
    my ($req, $consumed) = $protocol->parse_request($short_request);
    ok($req && !$req->{error}, "Short request line accepted");
    is($req->{method}, 'GET', "Method parsed correctly");

    # Long request line should be rejected with 414
    my $long_uri = "/very" . ("x" x 200) . "/long/uri";
    my $long_request = "GET $long_uri HTTP/1.1\r\nHost: localhost\r\n\r\n";
    ($req, $consumed) = $protocol->parse_request($long_request);
    ok($req && $req->{error}, "Long request line rejected");
    is($req->{error}, 414, "Returns 414 URI Too Long");
    is($req->{message}, 'URI Too Long', "Correct error message");
};

subtest 'Request line limit enforced by server' => sub {
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
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

        await $send->({
            type => 'http.response.start',
            status => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'OK',
            more => 0,
        });
    };

    my $server = PAGI::Server->new(
        app   => $app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;
    my $port = $server->port;

    # Send request with very long URI (exceeds default 8KB)
    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 2,
    ) or die "Cannot connect: $!";

    my $long_uri = "/path" . ("x" x 10000);  # Over 8KB
    print $sock "GET $long_uri HTTP/1.1\r\nHost: localhost\r\n\r\n";

    my $response = '';
    $sock->blocking(0);
    my $deadline = time + 2;
    while (time < $deadline) {
        $loop->loop_once(0.1);
        my $data;
        my $bytes = sysread($sock, $data, 4096);
        if (defined $bytes && $bytes > 0) {
            $response .= $data;
        }
        last if $response =~ /\r\n\r\n/;
    }
    close($sock);

    like($response, qr/HTTP\/1\.1 414/, "Server returns 414 for long URI");

    $server->shutdown->get;
    eval { $loop->remove($server) };
};

# =============================================================================
# Test 4.2: Server Header
# =============================================================================

subtest 'Server header added to responses (4.2)' => sub {
    my $protocol = PAGI::Server::Protocol::HTTP1->new;

    # Response without Server header - should add default
    my $headers = [
        ['content-type', 'text/plain'],
        ['content-length', '2'],
    ];
    my $response = $protocol->serialize_response_start(200, $headers);
    like($response, qr/Server: PAGI\//, "Default Server header added");

    # Response with custom Server header - should NOT add default
    my $headers_with_server = [
        ['content-type', 'text/plain'],
        ['Server', 'MyCustomServer/1.0'],
    ];
    $response = $protocol->serialize_response_start(200, $headers_with_server);
    like($response, qr/MyCustomServer/, "Custom Server header preserved");
    unlike($response, qr/Server: PAGI\//, "Default Server header NOT added when custom provided");
};

subtest 'Server header in actual responses' => sub {
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
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

        await $send->({
            type => 'http.response.start',
            status => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'OK',
            more => 0,
        });
    };

    my $server = PAGI::Server->new(
        app   => $app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;
    my $port = $server->port;

    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 2,
    ) or die "Cannot connect: $!";

    print $sock "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";

    my $response = '';
    $sock->blocking(0);
    my $deadline = time + 2;
    while (time < $deadline) {
        $loop->loop_once(0.1);
        my $data;
        my $bytes = sysread($sock, $data, 4096);
        if (defined $bytes && $bytes > 0) {
            $response .= $data;
        }
        elsif (!defined $bytes && $! == POSIX::EAGAIN()) {
            # Would block
        }
        else {
            last;
        }
    }
    close($sock);

    like($response, qr/Server: PAGI\//, "Response includes Server header");

    $server->shutdown->get;
    eval { $loop->remove($server) };
};

# =============================================================================
# Test 4.4: Certificate File Validation at Startup
# =============================================================================

subtest 'Certificate file validation at startup (4.4)' => sub {
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        # Minimal app
        if ($scope->{type} eq 'lifespan') {
            while (1) {
                my $event = await $receive->();
                last if $event->{type} eq 'lifespan.shutdown';
                await $send->({ type => 'lifespan.startup.complete' })
                    if $event->{type} eq 'lifespan.startup';
            }
            return;
        }
    };

    # Test non-existent cert file
    my $error;
    eval {
        PAGI::Server->new(
            app  => $app,
            host => '127.0.0.1',
            port => 0,
            ssl  => { cert_file => '/nonexistent/cert.pem' },
        );
    };
    $error = $@;
    like($error, qr/SSL certificate file not found/, "Fails on non-existent cert");

    # Test non-existent key file
    eval {
        PAGI::Server->new(
            app  => $app,
            host => '127.0.0.1',
            port => 0,
            ssl  => { key_file => '/nonexistent/key.pem' },
        );
    };
    $error = $@;
    like($error, qr/SSL key file not found/, "Fails on non-existent key");

    # Test non-existent CA file
    eval {
        PAGI::Server->new(
            app  => $app,
            host => '127.0.0.1',
            port => 0,
            ssl  => { ca_file => '/nonexistent/ca.pem' },
        );
    };
    $error = $@;
    like($error, qr/SSL CA file not found/, "Fails on non-existent CA");

    # Test unreadable file (if we can create one)
    SKIP: {
        skip "Cannot test unreadable files as root", 1 if $> == 0;

        my $tmpfile = "/tmp/pagi_test_unreadable_$$";
        open my $fh, '>', $tmpfile or skip "Cannot create temp file", 1;
        close $fh;
        chmod 0000, $tmpfile;

        eval {
            PAGI::Server->new(
                app  => $app,
                host => '127.0.0.1',
                port => 0,
                ssl  => { cert_file => $tmpfile },
            );
        };
        $error = $@;
        like($error, qr/SSL certificate file not readable/, "Fails on unreadable cert");

        chmod 0644, $tmpfile;
        unlink $tmpfile;
    }
};

done_testing;
