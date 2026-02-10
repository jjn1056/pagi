use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use IO::Async::Timer::Countdown;
use Net::Async::HTTP;
use Future::AsyncAwait;
use URI;
use FindBin;
use File::Spec;

use PAGI::Server;

# Skip entire test if TLS modules not installed
BEGIN {
    my $tls_available = eval {
        require IO::Async::SSL;
        require IO::Socket::SSL;
        1;
    };
    unless ($tls_available) {
        require Test2::V0;
        Test2::V0::plan(skip_all => 'TLS modules not installed (optional)');
    }
}

plan skip_all => "Server integration tests not supported on Windows" if $^O eq 'MSWin32';

# Step 8: TLS Support
# Tests for examples/08-tls-introspection/app.pl

my $loop = IO::Async::Loop->new;

# Path to test certificates
my $cert_dir = "$FindBin::Bin/certs";
my $server_cert = "$cert_dir/server.crt";
my $server_key = "$cert_dir/server.key";
my $ca_cert = "$cert_dir/ca.crt";
my $client_cert = "$cert_dir/client.crt";
my $client_key = "$cert_dir/client.key";

# Check if certificates exist
unless (-f $server_cert && -f $server_key) {
    plan skip_all => 'Test certificates not found - run test setup';
}

# Load the example app
my $app_path = "$FindBin::Bin/../examples/08-tls-introspection/app.pl";
my $app = do $app_path;
die "Could not load app from $app_path: $@" if $@;
die "App did not return a coderef" unless ref $app eq 'CODE';

# Test 1: HTTPS connection works with 08-tls-introspection example app
subtest 'HTTPS connection works with TLS introspection app' => sub {
    my $server = PAGI::Server->new(
        app   => $app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
        ssl   => {
            cert_file => $server_cert,
            key_file  => $server_key,
        },
    );

    $loop->add($server);
    $server->listen->get;

    ok($server->is_running, 'Server is running');

    my $port = $server->port;

    my $http = Net::Async::HTTP->new(
        SSL_verify_mode => 0,  # Don't verify self-signed cert
    );
    $loop->add($http);

    my $response = $http->GET("https://127.0.0.1:$port/")->get;

    is($response->code, 200, 'HTTPS response status is 200 OK');
    like($response->decoded_content, qr/TLS info:/, 'Response contains TLS info');
    like($response->decoded_content, qr/tls_version/, 'Response contains tls_version');

    $server->shutdown->get;
    $loop->remove($server);
    $loop->remove($http);
};

# Test 2: TLS connection has tls extension in scope with correct info
subtest 'TLS connection populates scope.extensions.tls' => sub {
    my $captured_scope;

    my $tls_test_app = async sub  {
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

        die "Unsupported scope type: $scope->{type}" unless $scope->{type} eq 'http';

        $captured_scope = $scope;

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type => 'http.response.body',
            body => 'OK',
            more => 0,
        });
    };

    my $server = PAGI::Server->new(
        app   => $tls_test_app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
        ssl   => {
            cert_file => $server_cert,
            key_file  => $server_key,
        },
    );

    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;

    my $http = Net::Async::HTTP->new(
        SSL_verify_mode => 0,
    );
    $loop->add($http);

    my $response = $http->GET("https://127.0.0.1:$port/")->get;

    # Verify TLS extension is present
    ok(exists $captured_scope->{extensions}{tls}, 'scope.extensions.tls exists for TLS connection');

    my $tls = $captured_scope->{extensions}{tls};
    ok(ref $tls eq 'HASH', 'scope.extensions.tls is a hashref');

    # Check tls_version - should be present and a numeric value
    ok(defined $tls->{tls_version}, 'tls_version is defined');
    ok($tls->{tls_version} >= 0x0301, 'tls_version is at least TLS 1.0');

    # Check client_cert_chain is empty (no client cert in this test)
    is(ref $tls->{client_cert_chain}, 'ARRAY', 'client_cert_chain is arrayref');
    is(scalar @{$tls->{client_cert_chain}}, 0, 'client_cert_chain is empty (no client cert)');

    $server->shutdown->get;
    $loop->remove($server);
    $loop->remove($http);
};

# Test 3: TLS connection has scheme 'https'
subtest 'TLS connection has scheme https' => sub {
    my $captured_scope;

    my $scheme_test_app = async sub  {
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

        die "Unsupported scope type: $scope->{type}" unless $scope->{type} eq 'http';

        $captured_scope = $scope;

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type => 'http.response.body',
            body => 'OK',
            more => 0,
        });
    };

    my $server = PAGI::Server->new(
        app   => $scheme_test_app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
        ssl   => {
            cert_file => $server_cert,
            key_file  => $server_key,
        },
    );

    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;

    my $http = Net::Async::HTTP->new(
        SSL_verify_mode => 0,
    );
    $loop->add($http);

    my $response = $http->GET("https://127.0.0.1:$port/")->get;

    is($captured_scope->{scheme}, 'https', 'scope.scheme is https for TLS connection');

    $server->shutdown->get;
    $loop->remove($server);
    $loop->remove($http);
};

# Test 4: Non-TLS connection has no tls extension
subtest 'Non-TLS connection has no tls extension' => sub {
    my $captured_scope;

    my $no_tls_test_app = async sub  {
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

        die "Unsupported scope type: $scope->{type}" unless $scope->{type} eq 'http';

        $captured_scope = $scope;

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type => 'http.response.body',
            body => 'OK',
            more => 0,
        });
    };

    # Server WITHOUT TLS
    my $server = PAGI::Server->new(
        app   => $no_tls_test_app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
        # No ssl config
    );

    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;

    my $http = Net::Async::HTTP->new;
    $loop->add($http);

    my $response = $http->GET("http://127.0.0.1:$port/")->get;

    # Per spec: tls extension must be absent for non-TLS connections
    ok(!exists $captured_scope->{extensions}{tls}, 'scope.extensions.tls is absent for non-TLS connection');
    is($captured_scope->{scheme}, 'http', 'scope.scheme is http for non-TLS connection');

    $server->shutdown->get;
    $loop->remove($server);
    $loop->remove($http);
};

# Test 5: Non-TLS request to 08-tls-introspection app shows "not using TLS"
subtest 'Non-TLS request shows "Connection is not using TLS"' => sub {
    my $server = PAGI::Server->new(
        app   => $app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
        # No ssl config
    );

    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;

    my $http = Net::Async::HTTP->new;
    $loop->add($http);

    my $response = $http->GET("http://127.0.0.1:$port/")->get;

    is($response->code, 200, 'HTTP response status is 200 OK');
    like($response->decoded_content, qr/Connection is not using TLS/, 'Response indicates no TLS');

    $server->shutdown->get;
    $loop->remove($server);
    $loop->remove($http);
};

# Test 6: CLI launcher supports --ssl-cert and --ssl-key for HTTPS
subtest 'CLI launcher supports --ssl-cert and --ssl-key for HTTPS' => sub {
    use IPC::Open3;
    use Symbol 'gensym';

    my $app_path = "$FindBin::Bin/../examples/08-tls-introspection/app.pl";

    # Start server via CLI in background
    my $stderr = gensym;
    my $pid = open3(my $stdin, my $stdout, $stderr,
        'perl', '-Ilib', 'bin/pagi-server',
        '--app', $app_path,
        '--port', '0',  # Let OS choose port
        '--ssl-cert', $server_cert,
        '--ssl-key', $server_key,
        '--quiet'
    );

    # Give server time to start
    sleep 1;

    # Unfortunately with port 0 we can't easily get the port from CLI
    # So we'll just verify the process started without error
    my $running = kill(0, $pid);
    ok($running, 'CLI server process started with --ssl-cert and --ssl-key');

    # Clean up
    kill('TERM', $pid);
    waitpid($pid, 0);
};

# Test 7: TLS 1.2 minimum version is enforced
subtest 'TLS 1.2 minimum version is enforced by default' => sub {
    my $captured_scope;

    my $tls_version_app = async sub  {
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

        die "Unsupported scope type: $scope->{type}" unless $scope->{type} eq 'http';

        $captured_scope = $scope;

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type => 'http.response.body',
            body => 'OK',
            more => 0,
        });
    };

    my $server = PAGI::Server->new(
        app   => $tls_version_app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
        ssl   => {
            cert_file => $server_cert,
            key_file  => $server_key,
        },
    );

    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;

    my $http = Net::Async::HTTP->new(
        SSL_verify_mode => 0,
    );
    $loop->add($http);

    my $response = $http->GET("https://127.0.0.1:$port/")->get;

    ok(exists $captured_scope->{extensions}{tls}, 'scope.extensions.tls exists');

    my $tls = $captured_scope->{extensions}{tls};

    # TLS 1.2 = 0x0303, TLS 1.3 = 0x0304
    ok($tls->{tls_version} >= 0x0303, 'TLS version is at least TLS 1.2 (0x0303)');

    $server->shutdown->get;
    $loop->remove($server);
    $loop->remove($http);
};

# Test 8: Custom TLS min_version and cipher_list are configurable
subtest 'Custom TLS min_version and cipher_list are configurable' => sub {
    my $captured_scope;

    my $custom_tls_app = async sub  {
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

        die "Unsupported scope type: $scope->{type}" unless $scope->{type} eq 'http';

        $captured_scope = $scope;

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type => 'http.response.body',
            body => 'OK',
            more => 0,
        });
    };

    # Server with custom TLS settings
    my $server = PAGI::Server->new(
        app   => $custom_tls_app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
        ssl   => {
            cert_file   => $server_cert,
            key_file    => $server_key,
            min_version => 'TLSv1_2',  # Explicit min version
            cipher_list => 'ECDHE+AESGCM:DHE+AESGCM',  # Custom cipher list
        },
    );

    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;

    my $http = Net::Async::HTTP->new(
        SSL_verify_mode => 0,
    );
    $loop->add($http);

    my $response = $http->GET("https://127.0.0.1:$port/")->get;

    is($response->code, 200, 'HTTPS response with custom TLS settings is 200 OK');

    my $tls = $captured_scope->{extensions}{tls};
    ok($tls->{tls_version} >= 0x0303, 'TLS version meets minimum requirement');

    $server->shutdown->get;
    $loop->remove($server);
    $loop->remove($http);
};

# Test 9: verify_client requires client certificate (connection fails without one)
subtest 'verify_client requires client certificate' => sub {
    my $strict_app = async sub  {
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
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type => 'http.response.body',
            body => 'OK',
            more => 0,
        });
    };

    # Server requiring client certificate
    my $server = PAGI::Server->new(
        app   => $strict_app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
        ssl   => {
            cert_file     => $server_cert,
            key_file      => $server_key,
            ca_file       => $ca_cert,
            verify_client => 1,
        },
    );

    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;

    # Client WITHOUT certificate - should fail
    my $http_no_cert = Net::Async::HTTP->new(
        SSL_verify_mode => 0,
        # No SSL_cert_file or SSL_key_file
    );
    $loop->add($http_no_cert);

    my $failed = 0;
    eval {
        my $response = $http_no_cert->GET("https://127.0.0.1:$port/")->get;
    };
    if ($@) {
        $failed = 1;
        like($@, qr/SSL|certificate|handshake|connection/i, 'Connection failed due to missing client certificate');
    }
    ok($failed, 'Connection without client certificate was rejected');

    $loop->remove($http_no_cert);

    # Client WITH certificate - should succeed
    my $http_with_cert = Net::Async::HTTP->new(
        SSL_verify_mode => 0,
        SSL_cert_file   => $client_cert,
        SSL_key_file    => $client_key,
    );
    $loop->add($http_with_cert);

    my $response = $http_with_cert->GET("https://127.0.0.1:$port/")->get;
    is($response->code, 200, 'Connection with client certificate succeeds');

    $server->shutdown->get;
    $loop->remove($server);
    $loop->remove($http_with_cert);
};

# Test 10: Client certificates are captured when provided
subtest 'Client certificates are captured when provided' => sub {
    my $captured_scope;

    my $client_cert_app = async sub  {
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

        die "Unsupported scope type: $scope->{type}" unless $scope->{type} eq 'http';

        $captured_scope = $scope;

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type => 'http.response.body',
            body => 'OK',
            more => 0,
        });
    };

    # Server with client cert verification enabled
    my $server = PAGI::Server->new(
        app   => $client_cert_app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
        ssl   => {
            cert_file     => $server_cert,
            key_file      => $server_key,
            ca_file       => $ca_cert,
            verify_client => 1,
        },
    );

    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;

    # Create HTTP client with client certificate
    my $http = Net::Async::HTTP->new(
        SSL_verify_mode => 0,  # Don't verify server cert
        SSL_cert_file   => $client_cert,
        SSL_key_file    => $client_key,
    );
    $loop->add($http);

    my $response = $http->GET("https://127.0.0.1:$port/")->get;

    is($response->code, 200, 'HTTPS response with client cert is 200 OK');

    # Verify client cert info is captured
    ok(exists $captured_scope->{extensions}{tls}, 'scope.extensions.tls exists');

    my $tls = $captured_scope->{extensions}{tls};

    # Check client_cert_chain is populated
    is(ref $tls->{client_cert_chain}, 'ARRAY', 'client_cert_chain is arrayref');
    ok(scalar @{$tls->{client_cert_chain}} > 0, 'client_cert_chain contains certificates');

    # Check client_cert_name contains DN
    ok(defined $tls->{client_cert_name}, 'client_cert_name is defined');
    like($tls->{client_cert_name}, qr/Test Client/, 'client_cert_name contains expected CN');

    $server->shutdown->get;
    $loop->remove($server);
    $loop->remove($http);
};

# Test 11: SSL context is pre-created and shared (avoids per-connection CA bundle parsing)
subtest 'SSL context is pre-created for connection reuse' => sub {
    my $request_count = 0;

    my $concurrent_app = async sub {
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

        die "Unsupported scope type: $scope->{type}" unless $scope->{type} eq 'http';

        $request_count++;

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type => 'http.response.body',
            body => 'OK',
            more => 0,
        });
    };

    my $server = PAGI::Server->new(
        app   => $concurrent_app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
        ssl   => {
            cert_file => $server_cert,
            key_file  => $server_key,
        },
    );

    $loop->add($server);
    $server->listen->get;

    # Verify pre-created SSL context exists
    ok(defined $server->{_ssl_ctx}, 'SSL context is pre-created after listen');
    isa_ok($server->{_ssl_ctx}, ['IO::Socket::SSL::SSL_Context'],
        'SSL context is an IO::Socket::SSL::SSL_Context instance');

    my $port = $server->port;

    # Make 3 concurrent TLS requests
    my @http_clients;
    my @futures;
    for my $i (1..3) {
        my $http = Net::Async::HTTP->new(
            SSL_verify_mode => 0,
        );
        $loop->add($http);
        push @http_clients, $http;
        push @futures, $http->GET("https://127.0.0.1:$port/");
    }

    my @responses = Future->needs_all(@futures)->get;

    is(scalar @responses, 3, 'All 3 concurrent requests completed');
    for my $i (0..2) {
        is($responses[$i]->code, 200, "Concurrent request " . ($i+1) . " returned 200");
    }
    is($request_count, 3, 'Server handled all 3 requests');

    $server->shutdown->get;
    $loop->remove($server);
    $loop->remove($_) for @http_clients;
};

# Test 12: _build_ssl_config extracts and shares SSL configuration
subtest 'SSL config is built and shared via _build_ssl_config' => sub {
    my $server = PAGI::Server->new(
        app   => sub {},
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
        ssl   => {
            cert_file => $server_cert,
            key_file  => $server_key,
        },
    );

    # _build_ssl_config should exist and return SSL params
    ok($server->can('_build_ssl_config'), '_build_ssl_config method exists');

    my $ssl_params = $server->_build_ssl_config;
    ok(defined $ssl_params, '_build_ssl_config returns defined value');
    is(ref $ssl_params, 'HASH', '_build_ssl_config returns a hashref');

    # Check expected keys
    ok($ssl_params->{SSL_server}, 'SSL_server is set');
    is($ssl_params->{SSL_cert_file}, $server_cert, 'SSL_cert_file matches');
    is($ssl_params->{SSL_key_file}, $server_key, 'SSL_key_file matches');
    ok(defined $ssl_params->{SSL_version}, 'SSL_version is set');
    ok(defined $ssl_params->{SSL_cipher_list}, 'SSL_cipher_list is set');
    is($ssl_params->{SSL_verify_mode}, 0x00, 'SSL_verify_mode is VERIFY_NONE by default');

    # Check shared SSL context
    ok(defined $server->{_ssl_ctx}, 'SSL context is stored on server');
    isa_ok($server->{_ssl_ctx}, ['IO::Socket::SSL::SSL_Context'],
        'SSL context is correct type');
    is($ssl_params->{SSL_reuse_ctx}, $server->{_ssl_ctx},
        'SSL_reuse_ctx points to shared context');

    # Check tls_enabled flag
    is($server->{tls_enabled}, 1, 'tls_enabled is set');

    # Check extensions.tls is auto-added
    ok(exists $server->{extensions}{tls}, 'extensions.tls is auto-added');
};

# Test 13: _build_ssl_config returns undef when no SSL configured
subtest '_build_ssl_config returns undef without SSL' => sub {
    my $server = PAGI::Server->new(
        app   => sub {},
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
    );

    my $ssl_params = $server->_build_ssl_config;
    ok(!defined $ssl_params, '_build_ssl_config returns undef without SSL');
    ok(!$server->{tls_enabled}, 'tls_enabled is not set');
};

# Test 14: Multi-worker TLS connections work
subtest 'Multi-worker TLS connections work' => sub {
    use POSIX ':sys_wait_h';

    my $tls_worker_app = async sub {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} eq 'lifespan') {
            while (1) {
                my $event = await $receive->();
                if ($event->{type} eq 'lifespan.startup') {
                    await $send->({ type => 'lifespan.startup.complete' });
                }
                elsif ($event->{type} eq 'lifespan.shutdown') {
                    await $send->({ type => 'lifespan.shutdown.complete' });
                    return;
                }
            }
        }
        elsif ($scope->{type} eq 'http') {
            while (1) {
                my $event = await $receive->();
                last if $event->{type} ne 'http.request';
                last unless $event->{more};
            }
            await $send->({
                type    => 'http.response.start',
                status  => 200,
                headers => [['content-type', 'text/plain']],
            });
            await $send->({
                type => 'http.response.body',
                body => "OK from worker $$",
                more => 0,
            });
        }
    };

    # Use a pipe so the child can signal readiness with the actual port
    pipe(my $read_fh, my $write_fh) or die "pipe: $!";

    my $server_pid = fork();
    die "Fork failed: $!" unless defined $server_pid;

    if ($server_pid == 0) {
        # Child: run multi-worker server with TLS
        close $read_fh;
        my $child_loop = IO::Async::Loop->new;
        my $server = PAGI::Server->new(
            app     => $tls_worker_app,
            host    => '127.0.0.1',
            port    => 0,  # OS assigns a free port
            workers => 2,
            quiet   => 1,
            ssl     => {
                cert_file => $server_cert,
                key_file  => $server_key,
            },
        );
        $child_loop->add($server);
        $server->listen->get;
        # Signal readiness with the assigned port
        print $write_fh $server->port . "\n";
        close $write_fh;
        $child_loop->run;
        exit(0);
    }

    # Parent: wait for child to signal readiness with port
    close $write_fh;
    my $port = <$read_fh>;
    close $read_fh;

    unless (defined $port && $port =~ /^\d+$/) {
        fail('Server child failed to start');
        kill 'KILL', $server_pid;
        waitpid($server_pid, 0);
        return;
    }
    chomp $port;

    # Wait for workers to be ready to accept TLS connections.
    # The listen socket is bound but forked workers may not have entered
    # their accept loops yet, causing TLS handshake failures.
    my $ready = 0;
    for my $attempt (1..20) {
        my $sock = eval {
            IO::Socket::SSL->new(
                PeerAddr        => '127.0.0.1',
                PeerPort        => $port,
                SSL_verify_mode => 0,
                Timeout         => 1,
            );
        };
        if ($sock) {
            close $sock;
            $ready = 1;
            last;
        }
        select(undef, undef, undef, 0.25);
    }
    unless ($ready) {
        fail('Multi-worker TLS server did not become ready');
        kill 'TERM', $server_pid;
        waitpid($server_pid, 0);
        return;
    }

    # Verify HTTPS requests work through multi-worker TLS
    my $http = Net::Async::HTTP->new(
        SSL_verify_mode => 0,
    );
    $loop->add($http);

    my $response_ok = 0;
    my $response_body;
    eval {
        my $response = $http->GET("https://127.0.0.1:$port/")->get;
        $response_ok = ($response->code == 200);
        $response_body = $response->decoded_content;
    };
    if ($@) {
        diag("HTTPS request to multi-worker server failed: $@");
    }

    ok($response_ok, 'HTTPS response from multi-worker TLS server is 200 OK');
    like($response_body // '', qr/OK from worker/, 'Response body from worker');

    # Make a second request to verify TLS works across connections
    my $response2_ok = 0;
    eval {
        my $response2 = $http->GET("https://127.0.0.1:$port/")->get;
        $response2_ok = ($response2->code == 200);
    };
    ok($response2_ok, 'Second HTTPS request also succeeds');

    # Clean up
    kill 'TERM', $server_pid;
    my $terminated = 0;
    for my $i (1..10) {
        my $result = waitpid($server_pid, WNOHANG);
        if ($result > 0) {
            $terminated = 1;
            last;
        }
        sleep(1);
    }
    unless ($terminated) {
        kill 'KILL', $server_pid;
        waitpid($server_pid, 0);
    }

    $loop->remove($http);
};

done_testing;
