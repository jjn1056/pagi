#!/usr/bin/env perl

use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;

use lib 'lib';

use PAGI::Middleware::AccessLog;
use PAGI::Middleware::RequestId;
use PAGI::Middleware::Runtime;

my $loop = IO::Async::Loop->new;

sub run_async {
    my ($code) = @_;
    my $future = $code->();
    $loop->await($future);
}

# =============================================================================
# Test: AccessLog middleware logs requests in combined format
# =============================================================================

subtest 'AccessLog logs requests with client IP, method, path, status, size' => sub {
    my @log_lines;
    my $mw = PAGI::Middleware::AccessLog->new(
        logger => sub { push @log_lines, @_ },
        format => 'combined',
    );

    my $app = async sub ($scope, $receive, $send) {
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'Hello, World!',
            more => 0,
        });
    };

    my $wrapped = $mw->wrap($app);

    run_async(async sub {
        await $wrapped->(
            {
                type         => 'http',
                path         => '/test/path',
                method       => 'GET',
                http_version => '1.1',
                query_string => 'foo=bar',
                client       => ['192.168.1.1', 12345],
                headers      => [
                    ['user-agent', 'TestAgent/1.0'],
                    ['referer', 'http://example.com/'],
                ],
            },
            async sub { { type => 'http.disconnect' } },
            async sub ($event) { },
        );
    });

    is scalar(@log_lines), 1, 'one log line written';

    my $log = $log_lines[0];
    like $log, qr/192\.168\.1\.1/, 'log contains client IP';
    like $log, qr/GET/, 'log contains method';
    like $log, qr/\/test\/path\?foo=bar/, 'log contains path with query';
    like $log, qr/200/, 'log contains status';
    like $log, qr/13/, 'log contains response size (13 bytes)';
    like $log, qr/TestAgent\/1\.0/, 'log contains user agent';
    like $log, qr/http:\/\/example\.com\//, 'log contains referer';
};

subtest 'AccessLog common format' => sub {
    my @log_lines;
    my $mw = PAGI::Middleware::AccessLog->new(
        logger => sub { push @log_lines, @_ },
        format => 'common',
    );

    my $app = async sub ($scope, $receive, $send) {
        await $send->({
            type    => 'http.response.start',
            status  => 201,
            headers => [],
        });
        await $send->({
            type => 'http.response.body',
            body => 'Created',
            more => 0,
        });
    };

    my $wrapped = $mw->wrap($app);

    run_async(async sub {
        await $wrapped->(
            {
                type   => 'http',
                path   => '/api/create',
                method => 'POST',
                client => ['10.0.0.1', 8080],
                headers => [],
            },
            async sub { { type => 'http.disconnect' } },
            async sub ($event) { },
        );
    });

    my $log = $log_lines[0];
    like $log, qr/10\.0\.0\.1/, 'common format contains IP';
    like $log, qr/POST/, 'common format contains method';
    like $log, qr/201/, 'common format contains status';
    unlike $log, qr/TestAgent/, 'common format does not contain user agent';
};

subtest 'AccessLog tiny format' => sub {
    my @log_lines;
    my $mw = PAGI::Middleware::AccessLog->new(
        logger => sub { push @log_lines, @_ },
        format => 'tiny',
    );

    my $app = async sub ($scope, $receive, $send) {
        await $send->({
            type    => 'http.response.start',
            status  => 404,
            headers => [],
        });
        await $send->({
            type => 'http.response.body',
            body => 'Not Found',
            more => 0,
        });
    };

    my $wrapped = $mw->wrap($app);

    run_async(async sub {
        await $wrapped->(
            {
                type   => 'http',
                path   => '/missing',
                method => 'GET',
                client => ['127.0.0.1', 9000],
                headers => [],
            },
            async sub { { type => 'http.disconnect' } },
            async sub ($event) { },
        );
    });

    my $log = $log_lines[0];
    like $log, qr/GET \/missing 404/, 'tiny format contains method, path, status';
    like $log, qr/\d+\.\d+s/, 'tiny format contains duration';
};

subtest 'AccessLog skips non-HTTP requests' => sub {
    my @log_lines;
    my $mw = PAGI::Middleware::AccessLog->new(
        logger => sub { push @log_lines, @_ },
    );

    my $app = async sub ($scope, $receive, $send) {
        await $send->({ type => 'websocket.accept', headers => [] });
    };

    my $wrapped = $mw->wrap($app);

    run_async(async sub {
        await $wrapped->(
            { type => 'websocket', path => '/ws' },
            async sub { { type => 'websocket.disconnect' } },
            async sub ($event) { },
        );
    });

    is scalar(@log_lines), 0, 'no log for websocket';
};

# =============================================================================
# Test: RequestId middleware generates unique request IDs
# =============================================================================

subtest 'RequestId generates unique IDs and adds to response' => sub {
    my $mw = PAGI::Middleware::RequestId->new;

    my $received_request_id;
    my $app = async sub ($scope, $receive, $send) {
        $received_request_id = $scope->{request_id};
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [],
        });
        await $send->({
            type => 'http.response.body',
            body => 'OK',
            more => 0,
        });
    };

    my $wrapped = $mw->wrap($app);

    # First request
    my @sent1;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/', method => 'GET', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub ($event) { push @sent1, $event },
        );
    });

    my $id1 = $received_request_id;
    ok $id1, 'request ID generated';
    like $id1, qr/^[a-f0-9-]+$/, 'request ID format is hex with dashes';

    # Check response header
    my $response_id1;
    for my $h (@{$sent1[0]{headers}}) {
        if (lc($h->[0]) eq 'x-request-id') {
            $response_id1 = $h->[1];
            last;
        }
    }
    is $response_id1, $id1, 'response header matches scope request_id';

    # Second request - should have different ID
    my @sent2;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/', method => 'GET', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub ($event) { push @sent2, $event },
        );
    });

    my $id2 = $received_request_id;
    isnt $id1, $id2, 'second request has different ID';
};

subtest 'RequestId trusts incoming header when configured' => sub {
    my $mw = PAGI::Middleware::RequestId->new(trust_incoming => 1);

    my $received_request_id;
    my $app = async sub ($scope, $receive, $send) {
        $received_request_id = $scope->{request_id};
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [],
        });
        await $send->({
            type => 'http.response.body',
            body => 'OK',
            more => 0,
        });
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            {
                type    => 'http',
                path    => '/',
                method  => 'GET',
                headers => [['x-request-id', 'my-custom-id-123']],
            },
            async sub { { type => 'http.disconnect' } },
            async sub ($event) { push @sent, $event },
        );
    });

    is $received_request_id, 'my-custom-id-123', 'incoming ID trusted';
};

subtest 'RequestId uses custom header name' => sub {
    my $mw = PAGI::Middleware::RequestId->new(header => 'X-Correlation-ID');

    my $app = async sub ($scope, $receive, $send) {
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [],
        });
        await $send->({
            type => 'http.response.body',
            body => 'OK',
            more => 0,
        });
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/', method => 'GET', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub ($event) { push @sent, $event },
        );
    });

    my $found;
    for my $h (@{$sent[0]{headers}}) {
        if ($h->[0] eq 'X-Correlation-ID') {
            $found = 1;
            last;
        }
    }
    ok $found, 'custom header name used';
};

# =============================================================================
# Test: Runtime middleware adds X-Runtime header
# =============================================================================

subtest 'Runtime adds X-Runtime header with valid duration' => sub {
    my $mw = PAGI::Middleware::Runtime->new;

    my $app = async sub ($scope, $receive, $send) {
        # Small delay to ensure measurable runtime
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [],
        });
        await $send->({
            type => 'http.response.body',
            body => 'OK',
            more => 0,
        });
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/', method => 'GET', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub ($event) { push @sent, $event },
        );
    });

    my $runtime;
    for my $h (@{$sent[0]{headers}}) {
        if (lc($h->[0]) eq 'x-runtime') {
            $runtime = $h->[1];
            last;
        }
    }

    ok defined $runtime, 'X-Runtime header present';
    like $runtime, qr/^\d+\.\d+$/, 'X-Runtime is valid decimal number';

    my $duration = $runtime + 0;
    ok $duration >= 0, 'duration is non-negative';
    ok $duration < 10, 'duration is reasonable (< 10 seconds)';
};

subtest 'Runtime uses custom header and precision' => sub {
    my $mw = PAGI::Middleware::Runtime->new(
        header    => 'X-Response-Time',
        precision => 3,
    );

    my $app = async sub ($scope, $receive, $send) {
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [],
        });
        await $send->({
            type => 'http.response.body',
            body => 'OK',
            more => 0,
        });
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/', method => 'GET', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub ($event) { push @sent, $event },
        );
    });

    my $runtime;
    for my $h (@{$sent[0]{headers}}) {
        if ($h->[0] eq 'X-Response-Time') {
            $runtime = $h->[1];
            last;
        }
    }

    ok defined $runtime, 'custom header name used';
    like $runtime, qr/^\d+\.\d{3}$/, 'precision is 3 decimal places';
};

subtest 'Runtime skips non-HTTP requests' => sub {
    my $mw = PAGI::Middleware::Runtime->new;

    my $app = async sub ($scope, $receive, $send) {
        await $send->({ type => 'websocket.accept', headers => [] });
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'websocket', path => '/ws' },
            async sub { { type => 'websocket.disconnect' } },
            async sub ($event) { push @sent, $event },
        );
    });

    # WebSocket accept shouldn't have X-Runtime header added
    my $has_runtime = 0;
    if ($sent[0] && $sent[0]{headers}) {
        for my $h (@{$sent[0]{headers}}) {
            if ($h->[0] eq 'X-Runtime') {
                $has_runtime = 1;
                last;
            }
        }
    }
    ok !$has_runtime, 'no X-Runtime for websocket';
};

done_testing;
