use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use IO::Async::Loop;
use IO::Async::Timer::Countdown;
use Net::Async::HTTP;
use Future::AsyncAwait;
use URI;
use FindBin;
use File::Spec;

use PAGI::Server;

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

    my $tls_test_app = async sub ($scope, $receive, $send) {
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

    my $scheme_test_app = async sub ($scope, $receive, $send) {
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

    my $no_tls_test_app = async sub ($scope, $receive, $send) {
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

done_testing;
