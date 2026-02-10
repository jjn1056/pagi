use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use FindBin;
use lib "$FindBin::Bin/../../lib";

plan skip_all => "Server integration tests not supported on Windows" if $^O eq 'MSWin32';

# ============================================================
# Test: PAGI::Server HTTP/2 configuration and ALPN
# ============================================================

use PAGI::Server;

my $loop = IO::Async::Loop->new;

my $app = sub { };

# ============================================================
# http2 flag is accepted and stored
# ============================================================
subtest 'http2 flag accepted by Server' => sub {
    my $server = PAGI::Server->new(
        app   => $app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
        http2 => 1,
    );

    ok($server->{http2}, 'http2 flag is stored');

    # Without http2 flag
    my $server2 = PAGI::Server->new(
        app   => $app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
    );

    ok(!$server2->{http2}, 'http2 defaults to off');
};

# ============================================================
# http2 via environment variable
# ============================================================
subtest 'http2 via _PAGI_SERVER_HTTP2 env var' => sub {
    local $ENV{_PAGI_SERVER_HTTP2} = 1;

    my $server = PAGI::Server->new(
        app   => $app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
    );

    ok($server->{http2}, 'http2 enabled via environment variable');
};

# ============================================================
# _build_ssl_config includes ALPN when http2 is enabled
# ============================================================
subtest 'SSL config includes ALPN with http2' => sub {
    plan skip_all => "IO::Async::SSL not installed" unless PAGI::Server->has_tls;

    my $server = PAGI::Server->new(
        app   => $app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
        http2 => 1,
        ssl   => {
            cert_file => "$FindBin::Bin/../../t/certs/server.crt",
            key_file  => "$FindBin::Bin/../../t/certs/server.key",
        },
    );

    $loop->add($server);

    my $ssl_config = $server->_build_ssl_config;
    ok($ssl_config, 'SSL config was built');
    is($ssl_config->{SSL_alpn_protocols}, ['h2', 'http/1.1'],
        'SSL config includes ALPN protocols for HTTP/2');

    ok($server->{http2_enabled}, 'http2_enabled flag is set');

    $loop->remove($server);
};

# ============================================================
# _build_ssl_config does NOT include ALPN without http2
# ============================================================
subtest 'SSL config excludes ALPN without http2' => sub {
    plan skip_all => "IO::Async::SSL not installed" unless PAGI::Server->has_tls;

    my $server = PAGI::Server->new(
        app   => $app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
        ssl   => {
            cert_file => "$FindBin::Bin/../../t/certs/server.crt",
            key_file  => "$FindBin::Bin/../../t/certs/server.key",
        },
    );

    $loop->add($server);

    my $ssl_config = $server->_build_ssl_config;
    ok($ssl_config, 'SSL config was built');
    ok(!exists $ssl_config->{SSL_alpn_protocols},
        'SSL config does not include ALPN without http2');

    ok(!$server->{http2_enabled}, 'http2_enabled is not set');

    $loop->remove($server);
};

# ============================================================
# HTTP/2 protocol singleton is created when http2 is enabled
# ============================================================
subtest 'HTTP/2 protocol singleton created' => sub {
    my $server = PAGI::Server->new(
        app   => $app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
        http2 => 1,
    );

    ok($server->{http2_protocol}, 'http2_protocol object created');
    isa_ok($server->{http2_protocol}, 'PAGI::Server::Protocol::HTTP2');
};

# ============================================================
# HTTP/2 protocol singleton NOT created when http2 is off
# ============================================================
subtest 'HTTP/2 protocol singleton not created when off' => sub {
    my $server = PAGI::Server->new(
        app   => $app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
    );

    ok(!$server->{http2_protocol}, 'http2_protocol not created when off');
};

# ============================================================
# has_http2 class method
# ============================================================
subtest 'has_http2 reflects availability' => sub {
    # nghttp2 is installed on this system so it should be available
    ok(PAGI::Server->has_http2, 'has_http2 returns true when nghttp2 installed');
};

# ============================================================
# h2c_enabled flag for cleartext HTTP/2
# ============================================================
subtest 'h2c_enabled set for cleartext http2' => sub {
    my $server = PAGI::Server->new(
        app   => $app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
        http2 => 1,
        # No ssl config = cleartext
    );

    ok($server->{http2_enabled}, 'http2_enabled set for cleartext');
    ok($server->{h2c_enabled}, 'h2c_enabled set for cleartext http2');
};

subtest 'h2c_enabled NOT set for TLS http2' => sub {
    plan skip_all => "IO::Async::SSL not installed" unless PAGI::Server->has_tls;

    my $server = PAGI::Server->new(
        app   => $app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
        http2 => 1,
        ssl   => {
            cert_file => "$FindBin::Bin/../../t/certs/server.crt",
            key_file  => "$FindBin::Bin/../../t/certs/server.key",
        },
    );

    ok(!$server->{h2c_enabled}, 'h2c_enabled not set for TLS http2');
};

# ============================================================
# HTTP/2 protocol settings use sensible defaults
# ============================================================
subtest 'HTTP/2 protocol settings defaults' => sub {
    my $server = PAGI::Server->new(
        app   => $app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
        http2 => 1,
    );

    my $proto = $server->{http2_protocol};
    ok($proto, 'http2_protocol created');
    is($proto->{max_concurrent_streams}, 100, 'default max_concurrent_streams is 100');
    is($proto->{initial_window_size}, 65535, 'default initial_window_size is 65535');
    is($proto->{max_frame_size}, 16384, 'default max_frame_size is 16384');
    is($proto->{enable_push}, 0, 'default enable_push is 0');
    is($proto->{enable_connect_protocol}, 1, 'default enable_connect_protocol is 1');
    is($proto->{max_header_list_size}, 65536, 'default max_header_list_size is 65536');
};

# ============================================================
# HTTP/2 protocol settings can be customized
# ============================================================
subtest 'HTTP/2 protocol settings customization' => sub {
    my $server = PAGI::Server->new(
        app   => $app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
        http2 => 1,
        h2_max_concurrent_streams  => 200,
        h2_initial_window_size     => 131072,
        h2_max_frame_size          => 32768,
        h2_enable_push             => 1,
        h2_enable_connect_protocol => 0,
        h2_max_header_list_size    => 131072,
    );

    my $proto = $server->{http2_protocol};
    ok($proto, 'http2_protocol created with custom settings');
    is($proto->{max_concurrent_streams}, 200, 'custom max_concurrent_streams');
    is($proto->{initial_window_size}, 131072, 'custom initial_window_size');
    is($proto->{max_frame_size}, 32768, 'custom max_frame_size');
    is($proto->{enable_push}, 1, 'custom enable_push');
    is($proto->{enable_connect_protocol}, 0, 'custom enable_connect_protocol');
    is($proto->{max_header_list_size}, 131072, 'custom max_header_list_size');
};

# ============================================================
# HTTP/2 settings ignored when http2 is disabled
# ============================================================
subtest 'HTTP/2 settings ignored when http2 disabled' => sub {
    my $server = PAGI::Server->new(
        app   => $app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
        # http2 not set (defaults to 0)
        h2_max_concurrent_streams => 200,
    );

    ok(!$server->{http2_protocol}, 'no http2_protocol when http2 disabled');
};

done_testing;
