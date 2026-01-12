#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

# =============================================================================
# HTTP/2 Availability Tests
# =============================================================================
# Tests that HTTP/2 support is properly detected and available.

use PAGI::Server;

# Check HTTP/2 availability
ok(PAGI::Server->has_http2, 'HTTP/2 is available via PAGI::Server->has_http2');

# Check the underlying module
subtest 'Net::HTTP2::nghttp2 module' => sub {
    ok(eval { require Net::HTTP2::nghttp2; 1 }, 'require Net::HTTP2::nghttp2')
        or diag $@;
    ok(eval { require Net::HTTP2::nghttp2::Session; 1 }, 'require Net::HTTP2::nghttp2::Session')
        or diag $@;

    ok(Net::HTTP2::nghttp2->available, 'nghttp2 C library is available');
};

# Check the protocol handler
subtest 'PAGI::Server::Protocol::HTTP2' => sub {
    ok(eval { require PAGI::Server::Protocol::HTTP2; 1 }, 'require PAGI::Server::Protocol::HTTP2')
        or diag $@;

    ok(PAGI::Server::Protocol::HTTP2->available, 'Protocol handler reports available');

    my $proto = PAGI::Server::Protocol::HTTP2->new;
    isa_ok($proto, 'PAGI::Server::Protocol::HTTP2');

    # Check default settings
    is($proto->{max_concurrent_streams}, 100, 'default max_concurrent_streams is 100');
    is($proto->{initial_window_size}, 65535, 'default initial_window_size is 65535');
    is($proto->{max_frame_size}, 16384, 'default max_frame_size is 16384');
    is($proto->{enable_push}, 0, 'default enable_push is 0');
};

# Check custom settings
subtest 'Custom protocol settings' => sub {
    my $proto = PAGI::Server::Protocol::HTTP2->new(
        max_concurrent_streams => 50,
        initial_window_size    => 32768,
        max_frame_size         => 32768,
        enable_push            => 1,
    );

    is($proto->{max_concurrent_streams}, 50, 'custom max_concurrent_streams');
    is($proto->{initial_window_size}, 32768, 'custom initial_window_size');
    is($proto->{max_frame_size}, 32768, 'custom max_frame_size');
    is($proto->{enable_push}, 1, 'custom enable_push');
};

done_testing;
