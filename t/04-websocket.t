use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use Net::Async::WebSocket::Client;
use Future::AsyncAwait;
use FindBin;
use lib "$FindBin::Bin/../lib";

use PAGI::Server;

# Load example app
my $app_path = "$FindBin::Bin/../examples/04-websocket-echo/app.pl";
my $app = do $app_path;
die "Failed to load app from $app_path: $@" if $@;
die "App did not return coderef" unless ref $app eq 'CODE';

my $loop = IO::Async::Loop->new;

# Helper to create and start server
sub create_server {
    my ($test_app) = @_;
    $test_app //= $app;

    my $server = PAGI::Server->new(
        app   => $test_app,
        host  => '127.0.0.1',
        port  => 0,  # Random port
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;  # Wait for server to start

    return $server;
}

# Test 1: WebSocket handshake and echo
subtest 'WebSocket handshake and text echo' => sub {
    my $server = create_server();
    my $port = $server->port;

    my $client = Net::Async::WebSocket::Client->new(
        on_text_frame => sub {
            my ($self, $text) = @_;
            $self->{received_text} = $text;
        },
    );

    $loop->add($client);

    my $connected = 0;
    my $response_text = '';

    eval {
        $client->connect(
            url => "ws://127.0.0.1:$port/",
        )->get;

        $connected = 1;
        $client->send_text_frame("Hello");

        my $deadline = time + 5;
        while (!$client->{received_text} && time < $deadline) {
            $loop->loop_once(0.1);
        }

        $response_text = $client->{received_text} // '';
        $client->close;
    };

    ok($connected, 'WebSocket connection established');
    is($response_text, 'echo: Hello', 'Server echoed message correctly');

    $server->shutdown->get;
};

# Test 2: Binary frame echo
subtest 'WebSocket binary frame echo' => sub {
    my $server = create_server();
    my $port = $server->port;

    my $client = Net::Async::WebSocket::Client->new(
        on_binary_frame => sub {
            my ($self, $bytes) = @_;
            $self->{received_binary} = $bytes;
        },
    );

    $loop->add($client);

    my $response_bytes = '';
    my $binary = "\x00\x01\x02\x03\xFF\xFE";

    eval {
        $client->connect(
            url => "ws://127.0.0.1:$port/",
        )->get;

        $client->send_binary_frame($binary);

        my $deadline = time + 5;
        while (!$client->{received_binary} && time < $deadline) {
            $loop->loop_once(0.1);
        }

        $response_bytes = $client->{received_binary} // '';
        $client->close;
    };

    is($response_bytes, $binary, 'Binary frame echoed correctly');

    $server->shutdown->get;
};

# Test 3: Multiple messages
subtest 'Multiple messages in sequence' => sub {
    my $server = create_server();
    my $port = $server->port;

    my @received;
    my $client = Net::Async::WebSocket::Client->new(
        on_text_frame => sub {
            my ($self, $text) = @_;
            push @received, $text;
        },
    );

    $loop->add($client);

    eval {
        $client->connect(
            url => "ws://127.0.0.1:$port/",
        )->get;

        $client->send_text_frame("msg1");
        $client->send_text_frame("msg2");
        $client->send_text_frame("msg3");

        my $deadline = time + 5;
        while (scalar(@received) < 3 && time < $deadline) {
            $loop->loop_once(0.1);
        }

        $client->close;
    };

    is(scalar(@received), 3, 'Received 3 messages');
    is($received[0], 'echo: msg1', 'First message echoed');
    is($received[1], 'echo: msg2', 'Second message echoed');
    is($received[2], 'echo: msg3', 'Third message echoed');

    $server->shutdown->get;
};

# Test 4: Clean close handshake
subtest 'Clean close handshake' => sub {
    my $server = create_server();
    my $port = $server->port;

    my $close_received = 0;
    my $client = Net::Async::WebSocket::Client->new(
        on_text_frame => sub { },
        on_closed => sub {
            $close_received = 1;
        },
    );

    $loop->add($client);

    eval {
        $client->connect(
            url => "ws://127.0.0.1:$port/",
        )->get;

        $client->send_text_frame("test");
        $loop->loop_once(0.2);
        $client->close;

        my $deadline = time + 5;
        while (!$close_received && time < $deadline) {
            $loop->loop_once(0.1);
        }
    };

    ok($close_received, 'Close handshake completed');

    $server->shutdown->get;
};

# Test 5: WebSocket scope type is 'websocket'
subtest 'WebSocket scope type is websocket' => sub {
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

        my $event = await $receive->();
        await $send->({ type => 'websocket.accept' });
        await $send->({ type => 'websocket.close' });
    };

    my $server = create_server($test_app);
    my $port = $server->port;

    my $client = Net::Async::WebSocket::Client->new;
    $loop->add($client);

    eval {
        $client->connect(
            url => "ws://127.0.0.1:$port/",
        )->get;

        $loop->loop_once(0.5);
    };

    is($scope_type, 'websocket', 'Scope type is websocket');

    $server->shutdown->get;
};

# Test 6: Subprotocol in scope (simplified)
subtest 'Subprotocol parsing' => sub {
    my @received_subprotocols;
    my $app_called = 0;

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

        @received_subprotocols = @{$scope->{subprotocols} // []};
        $app_called = 1;

        my $event = await $receive->();
        await $send->({ type => 'websocket.accept' });
        await $send->({ type => 'websocket.close' });
    };

    my $server = create_server($test_app);
    my $port = $server->port;

    # Use raw socket to send specific Sec-WebSocket-Protocol header
    use IO::Socket::INET;
    use Digest::SHA qw(sha1_base64);

    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 5,
    );

    SKIP: {
        skip "Cannot connect", 2 unless $sock;

        my $key = 'dGhlIHNhbXBsZSBub25jZQ==';
        print $sock "GET / HTTP/1.1\r\n";
        print $sock "Host: 127.0.0.1:$port\r\n";
        print $sock "Upgrade: websocket\r\n";
        print $sock "Connection: Upgrade\r\n";
        print $sock "Sec-WebSocket-Key: $key\r\n";
        print $sock "Sec-WebSocket-Version: 13\r\n";
        print $sock "Sec-WebSocket-Protocol: echo, chat\r\n";
        print $sock "\r\n";

        # Wait for app to be called
        my $deadline = time + 3;
        while (!$app_called && time < $deadline) {
            $loop->loop_once(0.1);
        }

        is(scalar(@received_subprotocols), 2, 'Two subprotocols parsed');
        ok((grep { $_ eq 'echo' } @received_subprotocols), 'echo subprotocol found');

        close $sock;
    }

    $server->shutdown->get;
};

# Test 7: WebSocket upgrade rejection returns 403
subtest 'WebSocket rejection returns 403' => sub {
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

        my $event = await $receive->();
        # Reject the connection before accepting
        await $send->({ type => 'websocket.close' });
    };

    my $server = create_server($test_app);
    my $port = $server->port;

    # Use raw socket to capture HTTP response
    use IO::Socket::INET;
    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 5,
    );

    SKIP: {
        skip "Cannot connect", 1 unless $sock;

        my $key = 'dGhlIHNhbXBsZSBub25jZQ==';
        print $sock "GET / HTTP/1.1\r\n";
        print $sock "Host: 127.0.0.1:$port\r\n";
        print $sock "Upgrade: websocket\r\n";
        print $sock "Connection: Upgrade\r\n";
        print $sock "Sec-WebSocket-Key: $key\r\n";
        print $sock "Sec-WebSocket-Version: 13\r\n";
        print $sock "\r\n";

        # Set non-blocking read with timeout
        $sock->blocking(0);
        my $response = '';
        my $deadline = time + 3;
        while (time < $deadline) {
            my $buf;
            my $n = sysread($sock, $buf, 4096);
            if (defined $n && $n > 0) {
                $response .= $buf;
                last if $response =~ /\r\n\r\n/;
            }
            $loop->loop_once(0.1);
        }
        close $sock;

        like($response, qr/HTTP\/1\.1 403/, 'Rejection returns 403 Forbidden');
    }

    $server->shutdown->get;
};

done_testing;
