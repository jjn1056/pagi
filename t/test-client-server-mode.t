#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use File::Temp qw(tempdir);
use File::Spec;
use IO::Socket::INET;
use IO::Socket::UNIX;
use POSIX ':sys_wait_h';

use lib 'lib';
use PAGI::Test::Client;

plan skip_all => "Server tests not supported on Windows" if $^O eq 'MSWin32';

# Helper to wait for server to be ready
sub wait_for_server {
    my ($host, $port, $timeout) = @_;
    $timeout //= 5;
    my $start = time;
    while (time - $start < $timeout) {
        my $sock = IO::Socket::INET->new(
            PeerAddr => $host,
            PeerPort => $port,
            Proto    => 'tcp',
            Timeout  => 1,
        );
        if ($sock) {
            close $sock;
            return 1;
        }
        select(undef, undef, undef, 0.1);
    }
    return 0;
}

sub wait_for_socket {
    my ($path, $timeout) = @_;
    $timeout //= 5;
    my $start = time;
    while (time - $start < $timeout) {
        return 0 unless -e $path;
        my $sock = IO::Socket::UNIX->new(
            Peer => $path,
            Type => IO::Socket::UNIX::SOCK_STREAM(),
        );
        if ($sock) {
            close $sock;
            return 1;
        }
        select(undef, undef, undef, 0.1);
    }
    return 0;
}

# Read HTTP request from socket
sub read_http_request {
    my ($sock) = @_;
    my $request = '';
    my $timeout = 5;
    $sock->timeout($timeout);

    while (my $line = <$sock>) {
        $request .= $line;
        last if $line eq "\r\n";
    }
    return $request;
}

subtest 'constructor validation' => sub {
    # Must provide app, base_url, or socket
    like(
        dies { PAGI::Test::Client->new() },
        qr/Must provide either 'app'/,
        'Dies without app/base_url/socket'
    );

    # Cannot provide both app and base_url
    like(
        dies { PAGI::Test::Client->new(app => sub {}, base_url => 'http://localhost') },
        qr/Cannot provide both/,
        'Dies with both app and base_url'
    );

    # Invalid base_url
    like(
        dies { PAGI::Test::Client->new(base_url => 'not-a-url') },
        qr/Invalid base_url/,
        'Dies with invalid base_url'
    );

    # Valid base_url parses correctly
    my $client = PAGI::Test::Client->new(base_url => 'http://example.com:8080/api');
    is($client->{_scheme}, 'http', 'Scheme parsed');
    is($client->{_host}, 'example.com', 'Host parsed');
    is($client->{_port}, 8080, 'Port parsed');
    is($client->{_path_prefix}, '/api', 'Path prefix parsed');

    # Default port for http
    $client = PAGI::Test::Client->new(base_url => 'http://example.com');
    is($client->{_port}, 80, 'Default http port is 80');
};

subtest 'base_url mode with external server' => sub {
    # Start a simple HTTP server in background
    my $port = 15000 + int(rand(5000));

    my $pid = fork();
    if (!defined $pid) {
        fail "Cannot fork: $!";
        return;
    }

    if ($pid == 0) {
        # Child - simple HTTP server
        $SIG{TERM} = sub { exit(0) };
        $SIG{INT}  = sub { exit(0) };

        my $listener = IO::Socket::INET->new(
            LocalAddr => '127.0.0.1',
            LocalPort => $port,
            Proto     => 'tcp',
            Listen    => 5,
            ReuseAddr => 1,
        ) or exit(1);

        $listener->timeout(10);

        for (1..10) {  # Handle up to 10 requests
            my $client = $listener->accept or last;
            $client->autoflush(1);

            my $request = read_http_request($client);
            next unless $request;

            my ($method, $path) = $request =~ /^(\w+)\s+(\S+)/;
            $method //= 'GET';
            $path //= '/';

            require JSON::MaybeXS;
            my $body = JSON::MaybeXS::encode_json({ method => $method, path => $path });

            print $client "HTTP/1.1 200 OK\r\n";
            print $client "Content-Type: application/json\r\n";
            print $client "Content-Length: " . length($body) . "\r\n";
            print $client "Connection: close\r\n";
            print $client "\r\n";
            print $client $body;
            close $client;
        }
        close $listener;
        exit(0);
    }

    # Parent - test client
    ok(wait_for_server('127.0.0.1', $port), 'Server started') or do {
        kill 9, $pid;
        waitpid($pid, 0);
        return;
    };

    my $client = PAGI::Test::Client->new(
        base_url => "http://127.0.0.1:$port",
    );

    # Test GET
    my $res = $client->get('/test');
    is($res->status, 200, 'GET returns 200');
    my $data = $res->json;
    is($data->{method}, 'GET', 'Method is GET');
    is($data->{path}, '/test', 'Path is /test');

    # Test POST
    $res = $client->post('/api');
    $data = $res->json;
    is($data->{method}, 'POST', 'Method is POST');

    # Test with query
    $res = $client->get('/search', query => { q => 'perl' });
    $data = $res->json;
    like($data->{path}, qr{/search\?q=perl}, 'Path includes query');

    kill 'TERM', $pid;
    waitpid($pid, 0);
};

subtest 'socket mode with Unix domain socket' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    my $socket_path = File::Spec->catfile($tmpdir, 'test.sock');

    my $pid = fork();
    if (!defined $pid) {
        fail "Cannot fork: $!";
        return;
    }

    if ($pid == 0) {
        # Child - simple HTTP server on Unix socket
        $SIG{TERM} = sub { unlink $socket_path; exit(0) };
        $SIG{INT}  = sub { unlink $socket_path; exit(0) };

        unlink $socket_path if -e $socket_path;
        my $listener = IO::Socket::UNIX->new(
            Type   => IO::Socket::UNIX::SOCK_STREAM(),
            Local  => $socket_path,
            Listen => 5,
        ) or exit(1);

        for (1..10) {  # Handle up to 10 requests
            my $client = $listener->accept or last;
            $client->autoflush(1);

            my $request = read_http_request($client);
            next unless $request;

            print $client "HTTP/1.1 200 OK\r\n";
            print $client "Content-Type: text/plain\r\n";
            print $client "Content-Length: 12\r\n";
            print $client "Connection: close\r\n";
            print $client "\r\n";
            print $client "Hello, Unix!";
            close $client;
        }
        close $listener;
        unlink $socket_path;
        exit(0);
    }

    # Parent - wait for socket to appear and be connectable
    select(undef, undef, undef, 0.2);  # Brief delay for child to create socket
    ok(wait_for_socket($socket_path), 'Unix socket server started') or do {
        kill 9, $pid;
        waitpid($pid, 0);
        return;
    };

    my $client = PAGI::Test::Client->new(
        socket => $socket_path,
    );

    my $res = $client->get('/');
    is($res->status, 200, 'GET returns 200 via Unix socket');
    is($res->content, 'Hello, Unix!', 'Response body correct');

    # Test another request
    $res = $client->get('/another');
    is($res->status, 200, 'Second request works');

    kill 'TERM', $pid;
    waitpid($pid, 0);
};

subtest 'cookies persist in server mode' => sub {
    my $port = 16000 + int(rand(5000));

    my $pid = fork();
    if (!defined $pid) {
        fail "Cannot fork: $!";
        return;
    }

    if ($pid == 0) {
        # Child - server that sets/reads cookies
        $SIG{TERM} = sub { exit(0) };
        $SIG{INT}  = sub { exit(0) };

        my $listener = IO::Socket::INET->new(
            LocalAddr => '127.0.0.1',
            LocalPort => $port,
            Proto     => 'tcp',
            Listen    => 5,
            ReuseAddr => 1,
        ) or exit(1);

        $listener->timeout(10);

        for (1..10) {
            my $client = $listener->accept or last;
            $client->autoflush(1);

            my $request = read_http_request($client);
            next unless $request;

            my ($path) = $request =~ /^\w+\s+(\S+)/;
            $path //= '/';

            # Extract cookie header
            my ($cookie) = $request =~ /Cookie:\s*([^\r\n]+)/i;
            $cookie //= '';

            my $body = "cookie: $cookie";
            my @extra_headers;

            if ($path eq '/set') {
                push @extra_headers, "Set-Cookie: session=abc123; Path=/";
            }

            print $client "HTTP/1.1 200 OK\r\n";
            print $client "Content-Type: text/plain\r\n";
            print $client "Content-Length: " . length($body) . "\r\n";
            print $client "Connection: close\r\n";
            print $client "$_\r\n" for @extra_headers;
            print $client "\r\n";
            print $client $body;
            close $client;
        }
        close $listener;
        exit(0);
    }

    # Parent
    ok(wait_for_server('127.0.0.1', $port), 'Cookie server started') or do {
        kill 9, $pid;
        waitpid($pid, 0);
        return;
    };

    my $client = PAGI::Test::Client->new(
        base_url => "http://127.0.0.1:$port",
    );

    # Request that sets cookie
    my $res = $client->get('/set');
    is($res->status, 200, 'Set cookie request succeeded');
    is($client->cookie('session'), 'abc123', 'Cookie stored from Set-Cookie header');

    # Next request should send cookie
    $res = $client->get('/check');
    like($res->content, qr/session=abc123/, 'Cookie sent in subsequent request');

    kill 'TERM', $pid;
    waitpid($pid, 0);
};

# Cleanup
unlink 't/debug-server-mode.pl' if -e 't/debug-server-mode.pl';

done_testing;
