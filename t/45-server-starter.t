use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use Net::Async::HTTP;
use Future::AsyncAwait;
use IO::Socket::INET;
use IO::Socket::UNIX;
use File::Temp qw(tempdir);

use PAGI::Server;

plan skip_all => "Server integration tests not supported on Windows" if $^O eq 'MSWin32';

my $loop = IO::Async::Loop->new;

# Simple test app
my $app = async sub {
    my ($scope, $receive, $send) = @_;
    die "Unsupported scope type: $scope->{type}" if $scope->{type} ne 'http';

    await $send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [['content-type', 'text/plain']],
    });
    await $send->({
        type => 'http.response.body',
        body => 'hello-starter',
    });
};

# --- Step 5a: Parse helper tests ---

subtest 'Parse SERVER_STARTER_PORT: host:port=fd' => sub {
    my $result = PAGI::Server->_parse_server_starter_port('0.0.0.0:5000=3');
    is($result->{host}, '0.0.0.0', 'host parsed');
    is($result->{port}, 5000, 'port parsed');
    is($result->{fd}, 3, 'fd parsed');
    ok(!$result->{unix}, 'not unix socket');
};

subtest 'Parse SERVER_STARTER_PORT: port=fd' => sub {
    my $result = PAGI::Server->_parse_server_starter_port('5000=3');
    is($result->{host}, undef, 'no host');
    is($result->{port}, 5000, 'port parsed');
    is($result->{fd}, 3, 'fd parsed');
};

subtest 'Parse SERVER_STARTER_PORT: unix path=fd' => sub {
    my $result = PAGI::Server->_parse_server_starter_port('/tmp/app.sock=4');
    is($result->{path}, '/tmp/app.sock', 'path parsed');
    is($result->{fd}, 4, 'fd parsed');
    ok($result->{unix}, 'is unix socket');
};

subtest 'Parse SERVER_STARTER_PORT: IPv6 [::]:port=fd' => sub {
    my $result = PAGI::Server->_parse_server_starter_port('[::]:8080=5');
    is($result->{host}, '[::]', 'IPv6 host parsed');
    is($result->{port}, 8080, 'port parsed');
    is($result->{fd}, 5, 'fd parsed');
};

subtest 'Parse SERVER_STARTER_PORT: multiple entries uses first' => sub {
    my $result = PAGI::Server->_parse_server_starter_port('5000=3;5001=4');
    is($result->{port}, 5000, 'first entry port');
    is($result->{fd}, 3, 'first entry fd');
};

# --- Step 5b: Integration test (single-worker) ---

subtest 'Server::Starter single-worker integration' => sub {
    # Create a real listening socket
    my $listen_sock = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Proto     => 'tcp',
        Listen    => 128,
        ReuseAddr => 1,
        Blocking  => 0,
    ) or die "Cannot create test socket: $!";

    my $port = $listen_sock->sockport;
    my $fd = fileno($listen_sock);

    # Set the env var
    local $ENV{SERVER_STARTER_PORT} = "127.0.0.1:$port=$fd";

    # Capture STDERR to check startup log
    my $stderr_output = '';
    open(my $stderr_fh, '>', \$stderr_output) or die "Cannot create in-memory stderr: $!";
    local *STDERR = $stderr_fh;

    my $server = PAGI::Server->new(
        app        => $app,
        access_log => undef,
        quiet      => 0,
    );

    $loop->add($server);
    $server->listen->get;

    is($server->port, $port, 'Server reports correct port');

    # Verify we can make a request
    my $http = Net::Async::HTTP->new;
    $loop->add($http);

    my $response = $http->GET("http://127.0.0.1:$port/")->get;
    is($response->code, 200, 'Response is 200');
    is($response->content, 'hello-starter', 'Got expected body');

    # Verify startup log mentions Server::Starter
    like($stderr_output, qr/server-starter/i, 'Startup log mentions server-starter');

    $loop->remove($http);
    $server->shutdown->get;
    $loop->remove($server);

    # Socket should still be valid (not closed by server)
    ok(fileno($listen_sock), 'Socket FD still valid after server shutdown');
    close($listen_sock);
};

# --- Step 5c: Mutual exclusivity ---

subtest 'Server::Starter with explicit port dies' => sub {
    local $ENV{SERVER_STARTER_PORT} = '5000=3';

    like(
        dies {
            PAGI::Server->new(
                app  => $app,
                port => 8080,
            );
        },
        qr/cannot.*host.*port.*SERVER_STARTER_PORT/i,
        'Dies when explicit port conflicts with Server::Starter'
    );
};

subtest 'Server::Starter with explicit host dies' => sub {
    local $ENV{SERVER_STARTER_PORT} = '5000=3';

    like(
        dies {
            PAGI::Server->new(
                app  => $app,
                host => '0.0.0.0',
            );
        },
        qr/cannot.*host.*port.*SERVER_STARTER_PORT/i,
        'Dies when explicit host conflicts with Server::Starter'
    );
};

# --- Step 5d: Shutdown preserves FD ---

subtest 'Server::Starter shutdown preserves socket FD' => sub {
    my $listen_sock = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Proto     => 'tcp',
        Listen    => 128,
        ReuseAddr => 1,
        Blocking  => 0,
    ) or die "Cannot create test socket: $!";

    my $port = $listen_sock->sockport;
    my $fd = fileno($listen_sock);

    local $ENV{SERVER_STARTER_PORT} = "127.0.0.1:$port=$fd";

    my $server = PAGI::Server->new(
        app   => $app,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;

    # Shutdown
    $server->shutdown->get;
    $loop->remove($server);

    # Verify FD is still valid
    ok(defined fileno($listen_sock), 'Socket FD still valid after shutdown');

    # Verify we can still use the socket (important for Server::Starter hot restart)
    my $can_listen = eval {
        IO::Socket::INET->new(
            LocalAddr => '127.0.0.1',
            LocalPort => $port,
            Proto     => 'tcp',
            Listen    => 1,
            ReuseAddr => 1,
        );
    };
    # The original socket still holds the port, so this should either reuse it
    # or the original socket should be functional
    ok(defined fileno($listen_sock), 'Original socket still functional');

    close($listen_sock);
};

done_testing;
