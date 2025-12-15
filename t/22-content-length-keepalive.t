use strict;
use warnings;
use experimental 'signatures';
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
# Test 3.12: Content-Length Validation
# =============================================================================

subtest 'Content-Length validation in parser (3.12)' => sub {
    my $protocol = PAGI::Server::Protocol::HTTP1->new;

    # Valid Content-Length should work
    my $valid_request = "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nhello";
    my ($req, $consumed) = $protocol->parse_request($valid_request);
    ok($req && !$req->{error}, "Valid Content-Length accepted");
    is($req->{content_length}, 5, "Content-Length parsed correctly");

    # Negative Content-Length should be rejected
    my $negative_request = "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: -1\r\n\r\n";
    ($req, $consumed) = $protocol->parse_request($negative_request);
    ok($req && $req->{error}, "Negative Content-Length rejected");
    is($req->{error}, 400, "Returns 400 Bad Request");

    # Non-numeric Content-Length should be rejected
    my $nonnumeric_request = "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: abc\r\n\r\n";
    ($req, $consumed) = $protocol->parse_request($nonnumeric_request);
    ok($req && $req->{error}, "Non-numeric Content-Length rejected");
    is($req->{error}, 400, "Returns 400 Bad Request");

    # Overflow Content-Length should be rejected (larger than reasonable)
    my $overflow_request = "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 99999999999999999999\r\n\r\n";
    ($req, $consumed) = $protocol->parse_request($overflow_request);
    ok($req && $req->{error}, "Overflow Content-Length rejected");
    is($req->{error}, 413, "Returns 413 Payload Too Large");

    # Whitespace in Content-Length should be rejected (RFC 7230 Section 3.3.2)
    my $whitespace_request = "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5 \r\n\r\nhello";
    ($req, $consumed) = $protocol->parse_request($whitespace_request);
    ok($req && $req->{error}, "Whitespace in Content-Length rejected");
    is($req->{error}, 400, "Returns 400 Bad Request");
};

subtest 'Content-Length validation by server (3.12)' => sub {
    my $app = async sub ($scope, $receive, $send) {
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

    # Send request with negative Content-Length
    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 2,
    ) or die "Cannot connect: $!";

    print $sock "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: -1\r\n\r\n";

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

    like($response, qr/HTTP\/1\.1 400/, "Server returns 400 for negative Content-Length");

    $server->shutdown->get;
    eval { $loop->remove($server) };
};

# =============================================================================
# Test 3.15: HTTP/1.0 Keep-Alive Header
# =============================================================================

subtest 'HTTP/1.0 Keep-Alive advertisement (3.15)' => sub {
    my $app = async sub ($scope, $receive, $send) {
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
            headers => [
                ['content-type', 'text/plain'],
                ['content-length', '2'],
            ],
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

    # Send HTTP/1.0 request with Connection: keep-alive
    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 2,
    ) or die "Cannot connect: $!";

    print $sock "GET / HTTP/1.0\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n";

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
        last if $response =~ /OK$/;
    }
    close($sock);

    like($response, qr/HTTP\/1\.0 200/, "Response is HTTP/1.0");
    like($response, qr/Connection:\s*keep-alive/i, "Response includes Connection: keep-alive");

    $server->shutdown->get;
    eval { $loop->remove($server) };
};

subtest 'HTTP/1.0 without keep-alive should not advertise it' => sub {
    my $app = async sub ($scope, $receive, $send) {
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
            headers => [
                ['content-type', 'text/plain'],
                ['content-length', '2'],
            ],
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

    # Send HTTP/1.0 request WITHOUT Connection: keep-alive
    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 2,
    ) or die "Cannot connect: $!";

    print $sock "GET / HTTP/1.0\r\nHost: localhost\r\n\r\n";

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
        last if $response =~ /OK$/;
    }
    close($sock);

    like($response, qr/HTTP\/1\.0 200/, "Response is HTTP/1.0");
    unlike($response, qr/Connection:\s*keep-alive/i, "Response does NOT include Connection: keep-alive");

    $server->shutdown->get;
    eval { $loop->remove($server) };
};

subtest 'HTTP/1.1 should not need Connection: keep-alive' => sub {
    my $app = async sub ($scope, $receive, $send) {
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
            headers => [
                ['content-type', 'text/plain'],
                ['content-length', '2'],
            ],
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

    # Send HTTP/1.1 request (keep-alive is default)
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
        last if $response =~ /OK$/;
    }
    close($sock);

    like($response, qr/HTTP\/1\.1 200/, "Response is HTTP/1.1");
    # HTTP/1.1 shouldn't need to explicitly say keep-alive (it's default)
    # but should NOT have Connection: keep-alive when client sent close
    unlike($response, qr/Connection:\s*keep-alive/i, "HTTP/1.1 response does NOT add unnecessary keep-alive");

    $server->shutdown->get;
    eval { $loop->remove($server) };
};

done_testing;
