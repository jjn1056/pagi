use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use IO::Socket::INET;
use Future::AsyncAwait;
use POSIX qw(EAGAIN);
use FindBin;
use lib "$FindBin::Bin/../lib";

use PAGI::Server;

my $loop = IO::Async::Loop->new;

# Test: Server should handle exceptions in callbacks gracefully
# Issue 3.5: Uncaught exceptions in on_read callback can crash the server
# Specifically, Protocol::WebSocket::Frame throws exceptions for oversized payloads

subtest 'Server handles WebSocket oversized payload exception' => sub {
    my $ws_accepted = 0;

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

        if ($scope->{type} eq 'websocket') {
            await $send->({ type => 'websocket.accept' });
            $ws_accepted = 1;
            while (1) {
                my $event = await $receive->();
                last if $event->{type} eq 'websocket.disconnect';
            }
            return;
        }

        # HTTP request
        await $send->({
            type => 'http.response.start',
            status => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => "OK",
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

    # Test 1: Send WebSocket frame with payload size > max_payload_size
    # Protocol::WebSocket::Frame throws an exception for this
    {
        my $sock = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1',
            PeerPort => $port,
            Proto    => 'tcp',
            Timeout  => 2,
        ) or die "Cannot connect: $!";

        # WebSocket upgrade
        print $sock "GET / HTTP/1.1\r\n";
        print $sock "Host: localhost\r\n";
        print $sock "Upgrade: websocket\r\n";
        print $sock "Connection: Upgrade\r\n";
        print $sock "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n";
        print $sock "Sec-WebSocket-Version: 13\r\n";
        print $sock "\r\n";

        # Wait for upgrade response
        my $response = '';
        my $deadline = time + 2;
        $sock->blocking(0);
        while (time < $deadline) {
            $loop->loop_once(0.05);
            my $data;
            my $bytes = sysread($sock, $data, 4096);
            if (defined $bytes && $bytes > 0) {
                $response .= $data;
                last if $response =~ /\r\n\r\n/;
            }
        }

        ok($response =~ /101/, "WebSocket upgrade successful");

        # Wait for app to accept
        $deadline = time + 1;
        while (!$ws_accepted && time < $deadline) {
            $loop->loop_once(0.05);
        }

        # Now send a malformed frame that claims a massive payload size
        # This WILL trigger Protocol::WebSocket::Frame to throw an exception
        # Frame format: opcode (text=0x81), extended length (0x7F = use 8 byte length)
        # then 8 bytes indicating a payload of 0xFFFFFFFFFFFFFFFF (9223372036854775807 bytes)
        my $malicious_frame = pack('C', 0x81);  # Text frame
        $malicious_frame .= pack('C', 0x7F);    # Extended 64-bit length indicator
        $malicious_frame .= pack('Q>', 0xFFFFFFFFFFFFFFFF);  # Absurdly large length

        print $sock $malicious_frame;

        # Let the server process this - it should NOT crash
        # The server should catch the exception from Protocol::WebSocket::Frame
        # and close the connection gracefully without propagating to the event loop
        my $exception_leaked = 0;
        for (1..5) {
            eval { $loop->loop_once(0.1) };
            if ($@) {
                $exception_leaked = 1;
                diag("Event loop threw exception: $@");
                last;
            }
        }
        ok(!$exception_leaked, "Exception was caught and did not propagate to event loop");

        close($sock);
    }

    # Give server time to clean up
    $loop->loop_once(0.1);

    # Test 2: Verify server is still running by making a normal HTTP request
    {
        my $sock2 = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1',
            PeerPort => $port,
            Proto    => 'tcp',
            Timeout  => 2,
        );

        ok($sock2, "Can still connect to server after oversized frame");

        if ($sock2) {
            print $sock2 "GET / HTTP/1.1\r\n";
            print $sock2 "Host: localhost\r\n";
            print $sock2 "Connection: close\r\n";
            print $sock2 "\r\n";

            my $response = '';
            my $deadline = time + 2;
            $sock2->blocking(0);
            while (time < $deadline) {
                $loop->loop_once(0.1);
                my $data;
                my $bytes = sysread($sock2, $data, 4096);
                if (defined $bytes && $bytes > 0) {
                    $response .= $data;
                }
                elsif (!defined $bytes && $! == EAGAIN) {
                    # Would block, continue
                }
                else {
                    last;  # EOF or error
                }
            }

            ok($response =~ /200 OK/, "Server still responds after handling oversized frame");
            close($sock2);
        }
    }

    ok($server->is_running, "Server is still running");

    $server->shutdown->get;
    eval { $loop->remove($server) };
};

done_testing;
