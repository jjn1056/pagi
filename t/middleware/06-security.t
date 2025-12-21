#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;

use lib 'lib';

use PAGI::Middleware::CORS;
use PAGI::Middleware::SecurityHeaders;
use PAGI::Middleware::TrustedHosts;
use PAGI::Middleware::CSRF;

my $loop = IO::Async::Loop->new;

sub run_async {
    my ($code) = @_;
    my $future = $code->();
    $loop->await($future);
}

# =============================================================================
# Test: CORS middleware handles preflight requests
# =============================================================================

subtest 'CORS handles preflight OPTIONS request' => sub {
    my $mw = PAGI::Middleware::CORS->new(
        origins => ['https://example.com'],
        methods => ['GET', 'POST', 'PUT'],
        headers => ['Content-Type', 'Authorization'],
    );

    my $app_called = 0;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $app_called = 1;
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
                path    => '/api/resource',
                method  => 'OPTIONS',
                headers => [
                    ['origin', 'https://example.com'],
                    ['access-control-request-method', 'POST'],
                ],
            },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    ok !$app_called, 'app not called for preflight';
    is $sent[0]{status}, 204, 'preflight returns 204';

    my %headers = map { lc($_->[0]) => $_->[1] } @{$sent[0]{headers}};
    is $headers{'access-control-allow-origin'}, 'https://example.com', 'Allow-Origin header present';
    like $headers{'access-control-allow-methods'}, qr/POST/, 'Allow-Methods contains POST';
    like $headers{'access-control-allow-headers'}, qr/Content-Type/, 'Allow-Headers present';
};

subtest 'CORS adds headers to actual requests' => sub {
    my $mw = PAGI::Middleware::CORS->new(
        origins     => ['https://example.com'],
        credentials => 1,
    );

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'application/json']],
        });
        await $send->({
            type => 'http.response.body',
            body => '{"data":"test"}',
            more => 0,
        });
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            {
                type    => 'http',
                path    => '/api/data',
                method  => 'GET',
                headers => [['origin', 'https://example.com']],
            },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    my %headers = map { lc($_->[0]) => $_->[1] } @{$sent[0]{headers}};
    is $headers{'access-control-allow-origin'}, 'https://example.com', 'Origin header on response';
    is $headers{'access-control-allow-credentials'}, 'true', 'Credentials header present';
};

subtest 'CORS rejects unknown origins' => sub {
    my $mw = PAGI::Middleware::CORS->new(
        origins => ['https://allowed.com'],
    );

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
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
                path    => '/api/data',
                method  => 'GET',
                headers => [['origin', 'https://evil.com']],
            },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    # Response should not have CORS headers for unknown origin
    my @cors_headers = grep { $_->[0] =~ /^access-control/i } @{$sent[0]{headers}};
    is scalar(@cors_headers), 0, 'no CORS headers for unknown origin';
};

# =============================================================================
# Test: SecurityHeaders middleware adds security headers
# =============================================================================

subtest 'SecurityHeaders adds X-Content-Type-Options' => sub {
    my $mw = PAGI::Middleware::SecurityHeaders->new;

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/html']],
        });
        await $send->({
            type => 'http.response.body',
            body => '<html>Test</html>',
            more => 0,
        });
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/', method => 'GET', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    my %headers = map { lc($_->[0]) => $_->[1] } @{$sent[0]{headers}};
    is $headers{'x-content-type-options'}, 'nosniff', 'X-Content-Type-Options is nosniff';
};

subtest 'SecurityHeaders adds X-Frame-Options' => sub {
    my $mw = PAGI::Middleware::SecurityHeaders->new(
        x_frame_options => 'DENY',
    );

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
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
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    my %headers = map { lc($_->[0]) => $_->[1] } @{$sent[0]{headers}};
    is $headers{'x-frame-options'}, 'DENY', 'X-Frame-Options is DENY';
};

subtest 'SecurityHeaders adds all default headers' => sub {
    my $mw = PAGI::Middleware::SecurityHeaders->new;

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
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
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    my %headers = map { lc($_->[0]) => $_->[1] } @{$sent[0]{headers}};
    ok exists $headers{'x-frame-options'}, 'X-Frame-Options present';
    ok exists $headers{'x-content-type-options'}, 'X-Content-Type-Options present';
    ok exists $headers{'x-xss-protection'}, 'X-XSS-Protection present';
    ok exists $headers{'referrer-policy'}, 'Referrer-Policy present';
};

# =============================================================================
# Test: TrustedHosts middleware validates Host header
# =============================================================================

subtest 'TrustedHosts allows valid hosts' => sub {
    my $mw = PAGI::Middleware::TrustedHosts->new(
        hosts => ['example.com', 'www.example.com'],
    );

    my $app_called = 0;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $app_called = 1;
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
                headers => [['host', 'example.com']],
            },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    ok $app_called, 'app called for valid host';
    is $sent[0]{status}, 200, 'status is 200';
};

subtest 'TrustedHosts rejects invalid hosts' => sub {
    my $mw = PAGI::Middleware::TrustedHosts->new(
        hosts => ['example.com'],
    );

    my $app_called = 0;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $app_called = 1;
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            {
                type    => 'http',
                path    => '/',
                method  => 'GET',
                headers => [['host', 'evil.com']],
            },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    ok !$app_called, 'app not called for invalid host';
    is $sent[0]{status}, 400, 'status is 400 Bad Request';
};

subtest 'TrustedHosts supports wildcard patterns' => sub {
    my $mw = PAGI::Middleware::TrustedHosts->new(
        hosts => ['*.example.com'],
    );

    my $app_called = 0;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $app_called = 1;
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

    run_async(async sub {
        await $wrapped->(
            {
                type    => 'http',
                path    => '/',
                method  => 'GET',
                headers => [['host', 'api.example.com']],
            },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; },
        );
    });

    ok $app_called, 'wildcard pattern matches subdomain';
};

# =============================================================================
# Test: CSRF middleware validates tokens on POST requests
# =============================================================================

subtest 'CSRF rejects POST without token' => sub {
    my $mw = PAGI::Middleware::CSRF->new(secret => 'test-secret');

    my $app_called = 0;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $app_called = 1;
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            {
                type    => 'http',
                path    => '/submit',
                method  => 'POST',
                headers => [],
            },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    ok !$app_called, 'app not called without token';
    is $sent[0]{status}, 403, 'status is 403 Forbidden';
};

subtest 'CSRF allows POST with valid token' => sub {
    my $mw = PAGI::Middleware::CSRF->new(secret => 'test-secret');

    # Generate a token first with a GET request
    my $token;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $token = $scope->{csrf_token};
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

    # GET request to get token
    my @sent1;
    run_async(async sub {
        await $wrapped->(
            {
                type    => 'http',
                path    => '/',
                method  => 'GET',
                headers => [],
            },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent1, $event },
        );
    });

    ok $token, 'token generated on GET';

    # Extract Set-Cookie token
    my $cookie_token;
    for my $h (@{$sent1[0]{headers}}) {
        if (lc($h->[0]) eq 'set-cookie' && $h->[1] =~ /csrf_token=([^;]+)/) {
            $cookie_token = $1;
            last;
        }
    }
    ok $cookie_token, 'token set in cookie';

    # POST request with token
    my $post_called = 0;
    my $post_app = async sub  {
        my ($scope, $receive, $send) = @_;
        $post_called = 1;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [],
        });
        await $send->({
            type => 'http.response.body',
            body => 'Created',
            more => 0,
        });
    };

    my $wrapped2 = $mw->wrap($post_app);

    my @sent2;
    run_async(async sub {
        await $wrapped2->(
            {
                type    => 'http',
                path    => '/submit',
                method  => 'POST',
                headers => [
                    ['cookie', "csrf_token=$cookie_token"],
                    ['x-csrf-token', $cookie_token],
                ],
            },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent2, $event },
        );
    });

    ok $post_called, 'app called with valid token';
    is $sent2[0]{status}, 200, 'POST succeeds with valid token';
};

subtest 'CSRF allows GET without token' => sub {
    my $mw = PAGI::Middleware::CSRF->new(secret => 'test-secret');

    my $app_called = 0;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $app_called = 1;
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
                path    => '/page',
                method  => 'GET',
                headers => [],
            },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    ok $app_called, 'app called for GET without token';
    is $sent[0]{status}, 200, 'GET succeeds without token';
};

done_testing;
