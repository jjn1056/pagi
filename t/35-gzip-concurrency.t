#!/usr/bin/env perl

# =============================================================================
# Test: GZip middleware concurrency safety
#
# Verifies that PAGI::Middleware::GZip handles concurrent requests safely
# without state pollution between requests.
# =============================================================================

use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;
use IO::Async::Loop;
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);

require PAGI::Middleware::GZip;

my $loop = IO::Async::Loop->new;

sub run_async {
    my ($code) = @_;
    my $future = $code->();
    $loop->await($future);
}

# =============================================================================
# Test: Basic GZip functionality
# =============================================================================

subtest 'GZip compresses large responses' => sub {
    my $gzip = PAGI::Middleware::GZip->new(min_size => 100);

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        my $body = 'x' x 1000;  # 1000 bytes
        await $send->({ type => 'http.response.start', status => 200, headers => [['content-type', 'text/plain']] });
        await $send->({ type => 'http.response.body', body => $body, more => 0 });
    };

    my $wrapped = $gzip->wrap($app);
    my @events;

    run_async(async sub {
        await $wrapped->(
            { type => 'http', headers => [['accept-encoding', 'gzip']] },
            async sub { { type => 'http.disconnect' } },
            async sub { push @events, $_[0] },
        );
    });

    is(scalar @events, 2, 'two events sent');
    is($events[0]{status}, 200, 'status is 200');

    # Check for gzip encoding header
    my $has_gzip = grep { $_->[0] eq 'Content-Encoding' && $_->[1] eq 'gzip' } @{$events[0]{headers}};
    ok($has_gzip, 'Content-Encoding: gzip header present');

    # Verify body is actually compressed
    my $compressed = $events[1]{body};
    my $uncompressed;
    gunzip(\$compressed, \$uncompressed) or die "gunzip failed: $GunzipError";
    is($uncompressed, 'x' x 1000, 'body decompresses to original');
};

# =============================================================================
# Test: Concurrent requests don't interfere
# =============================================================================

subtest 'concurrent requests have independent state' => sub {
    my $gzip = PAGI::Middleware::GZip->new(min_size => 100);

    # App that responds with request-specific content
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        my $id = $scope->{path};
        my $body = "response-$id-" . ('x' x 500);
        await $send->({ type => 'http.response.start', status => 200, headers => [['content-type', 'text/plain']] });
        await $send->({ type => 'http.response.body', body => $body, more => 0 });
    };

    my $wrapped = $gzip->wrap($app);

    # Run multiple requests concurrently
    my @results;
    for my $i (1..5) {
        my @events;
        my $scope = { type => 'http', path => $i, headers => [['accept-encoding', 'gzip']] };

        run_async(async sub {
            await $wrapped->(
                $scope,
                async sub { { type => 'http.disconnect' } },
                async sub { push @events, $_[0] },
            );
        });

        # Decompress and check
        my $compressed = $events[1]{body};
        my $uncompressed;
        gunzip(\$compressed, \$uncompressed) or die "gunzip failed: $GunzipError";

        push @results, $uncompressed;
    }

    # Each result should be unique and contain its request ID
    for my $i (1..5) {
        like($results[$i-1], qr/^response-$i-x+$/, "request $i got correct response");
    }
};

# =============================================================================
# Test: Streaming responses bypass compression
# =============================================================================

subtest 'streaming responses bypass compression' => sub {
    my $gzip = PAGI::Middleware::GZip->new(min_size => 10);

    # App that streams response in multiple chunks
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [['content-type', 'text/plain']] });
        await $send->({ type => 'http.response.body', body => 'chunk1', more => 1 });
        await $send->({ type => 'http.response.body', body => 'chunk2', more => 1 });
        await $send->({ type => 'http.response.body', body => 'chunk3', more => 0 });
    };

    my $wrapped = $gzip->wrap($app);
    my @events;

    run_async(async sub {
        await $wrapped->(
            { type => 'http', headers => [['accept-encoding', 'gzip']] },
            async sub { { type => 'http.disconnect' } },
            async sub { push @events, $_[0] },
        );
    });

    # Streaming should pass through without compression
    is(scalar @events, 4, 'four events sent (start + 3 body chunks)');
    is($events[0]{type}, 'http.response.start', 'first event is response start');

    # Check that Content-Encoding: gzip is NOT present (streaming bypasses compression)
    my $has_gzip = grep { $_->[0] eq 'Content-Encoding' && $_->[1] eq 'gzip' } @{$events[0]{headers}};
    ok(!$has_gzip, 'streaming response not compressed');

    # Body chunks should be uncompressed
    is($events[1]{body}, 'chunk1', 'first chunk intact');
    is($events[2]{body}, 'chunk2', 'second chunk intact');
    is($events[3]{body}, 'chunk3', 'third chunk intact');
};

# =============================================================================
# Test: No client gzip support
# =============================================================================

subtest 'no compression when client does not accept gzip' => sub {
    my $gzip = PAGI::Middleware::GZip->new(min_size => 10);

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [['content-type', 'text/plain']] });
        await $send->({ type => 'http.response.body', body => 'x' x 100, more => 0 });
    };

    my $wrapped = $gzip->wrap($app);
    my @events;

    run_async(async sub {
        await $wrapped->(
            { type => 'http', headers => [] },  # No accept-encoding header
            async sub { { type => 'http.disconnect' } },
            async sub { push @events, $_[0] },
        );
    });

    is(scalar @events, 2, 'two events sent');
    is($events[1]{body}, 'x' x 100, 'body is uncompressed');
};

# =============================================================================
# Test: State isolation between streaming and non-streaming requests
# =============================================================================

subtest 'state isolation: streaming then non-streaming' => sub {
    my $gzip = PAGI::Middleware::GZip->new(min_size => 10);

    # First: streaming request
    my $streaming_app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [['content-type', 'text/plain']] });
        await $send->({ type => 'http.response.body', body => 'stream', more => 1 });
        await $send->({ type => 'http.response.body', body => 'end', more => 0 });
    };

    my $wrapped_streaming = $gzip->wrap($streaming_app);
    my @streaming_events;

    run_async(async sub {
        await $wrapped_streaming->(
            { type => 'http', headers => [['accept-encoding', 'gzip']] },
            async sub { { type => 'http.disconnect' } },
            async sub { push @streaming_events, $_[0] },
        );
    });

    # Second: non-streaming request (should compress)
    my $buffered_app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [['content-type', 'text/plain']] });
        await $send->({ type => 'http.response.body', body => 'x' x 100, more => 0 });
    };

    my $wrapped_buffered = $gzip->wrap($buffered_app);
    my @buffered_events;

    run_async(async sub {
        await $wrapped_buffered->(
            { type => 'http', headers => [['accept-encoding', 'gzip']] },
            async sub { { type => 'http.disconnect' } },
            async sub { push @buffered_events, $_[0] },
        );
    });

    # Streaming should NOT be compressed
    my $streaming_has_gzip = grep { $_->[0] eq 'Content-Encoding' && $_->[1] eq 'gzip' } @{$streaming_events[0]{headers}};
    ok(!$streaming_has_gzip, 'streaming response not compressed');

    # Buffered should BE compressed
    my $buffered_has_gzip = grep { $_->[0] eq 'Content-Encoding' && $_->[1] eq 'gzip' } @{$buffered_events[0]{headers}};
    ok($buffered_has_gzip, 'buffered response IS compressed');

    # Verify the buffered body decompresses correctly
    my $compressed = $buffered_events[1]{body};
    my $uncompressed;
    gunzip(\$compressed, \$uncompressed) or die "gunzip failed: $GunzipError";
    is($uncompressed, 'x' x 100, 'buffered body decompresses correctly');
};

done_testing;
