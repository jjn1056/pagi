#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;
use JSON::PP;

use PAGI::Middleware::Rewrite;
use PAGI::Middleware::HTTPSRedirect;
use PAGI::Middleware::ReverseProxy;
use PAGI::Middleware::Healthcheck;

my $loop = IO::Async::Loop->new;

sub make_scope {
    my (%opts) = @_;
    return {
        type         => 'http',
        method       => $opts{method} // 'GET',
        path         => $opts{path} // '/',
        scheme       => $opts{scheme} // 'http',
        query_string => $opts{query_string},
        headers      => $opts{headers} // [],
        client       => $opts{client} // ['192.168.1.100', 12345],
        server       => $opts{server} // ['127.0.0.1', 5000],
    };
}

sub run_async :prototype(&) {
    my ($code) = @_;
    $loop->await($code->());
}

# ===================
# Rewrite Middleware Tests
# ===================

subtest 'Rewrite middleware - exact match' => sub {
    my $rewrite = PAGI::Middleware::Rewrite->new(
        rules => [{ from => '/old', to => '/new' }],
    );

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $rewrite->wrap($app);
    my $scope = make_scope(path => '/old');

    run_async { $wrapped->($scope, async sub { {} }, async sub { }) };

    is $captured_scope->{path}, '/new', 'path rewritten';
    is $captured_scope->{original_path}, '/old', 'original path preserved';
};

subtest 'Rewrite middleware - regex with captures' => sub {
    my $rewrite = PAGI::Middleware::Rewrite->new(
        rules => [{ from => qr{^/user/(\d+)}, to => '/users/$1' }],
    );

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $rewrite->wrap($app);
    my $scope = make_scope(path => '/user/123');

    run_async { $wrapped->($scope, async sub { {} }, async sub { }) };

    is $captured_scope->{path}, '/users/123', 'path rewritten with capture';
};

subtest 'Rewrite middleware - redirect mode' => sub {
    my $rewrite = PAGI::Middleware::Rewrite->new(
        rules => [{ from => '/old', to => '/new' }],
        redirect => 1,
        redirect_code => 302,
    );

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $rewrite->wrap($app);
    my $scope = make_scope(path => '/old');

    my @events;
    run_async { $wrapped->($scope, async sub { {} }, async sub  {
        my ($e) = @_; push @events, $e }) };

    is $events[0]{status}, 302, 'redirect status';
    my %headers = map { lc($_->[0]) => $_->[1] } @{$events[0]{headers}};
    is $headers{location}, '/new', 'redirect location';
};

subtest 'Rewrite middleware - no match passes through' => sub {
    my $rewrite = PAGI::Middleware::Rewrite->new(
        rules => [{ from => '/old', to => '/new' }],
    );

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $rewrite->wrap($app);
    my $scope = make_scope(path => '/other');

    run_async { $wrapped->($scope, async sub { {} }, async sub { }) };

    is $captured_scope->{path}, '/other', 'path unchanged';
};

# ===================
# HTTPSRedirect Middleware Tests
# ===================

subtest 'HTTPSRedirect - redirects HTTP to HTTPS' => sub {
    my $redirect = PAGI::Middleware::HTTPSRedirect->new();

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $redirect->wrap($app);
    my $scope = make_scope(
        scheme  => 'http',
        path    => '/test',
        headers => [['Host', 'example.com']],
    );

    my @events;
    run_async { $wrapped->($scope, async sub { {} }, async sub  {
        my ($e) = @_; push @events, $e }) };

    is $events[0]{status}, 301, 'redirect status';
    my %headers = map { lc($_->[0]) => $_->[1] } @{$events[0]{headers}};
    is $headers{location}, 'https://example.com/test', 'redirects to HTTPS';
};

subtest 'HTTPSRedirect - passes through HTTPS' => sub {
    my $redirect = PAGI::Middleware::HTTPSRedirect->new();

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $redirect->wrap($app);
    my $scope = make_scope(scheme => 'https');

    my @events;
    run_async { $wrapped->($scope, async sub { {} }, async sub  {
        my ($e) = @_; push @events, $e }) };

    is $events[0]{status}, 200, 'HTTPS passes through';
};

subtest 'HTTPSRedirect - excludes paths' => sub {
    my $redirect = PAGI::Middleware::HTTPSRedirect->new(
        exclude => ['/health'],
    );

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $redirect->wrap($app);
    my $scope = make_scope(scheme => 'http', path => '/health');

    my @events;
    run_async { $wrapped->($scope, async sub { {} }, async sub  {
        my ($e) = @_; push @events, $e }) };

    is $events[0]{status}, 200, 'excluded path not redirected';
};

# ===================
# ReverseProxy Middleware Tests
# ===================

subtest 'ReverseProxy - updates client from X-Forwarded-For' => sub {
    my $proxy = PAGI::Middleware::ReverseProxy->new(
        trusted_proxies => ['127.0.0.1'],
    );

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $proxy->wrap($app);
    my $scope = make_scope(
        client  => ['127.0.0.1', 12345],
        headers => [['X-Forwarded-For', '203.0.113.50, 198.51.100.1']],
    );

    run_async { $wrapped->($scope, async sub { {} }, async sub { }) };

    is $captured_scope->{client}[0], '203.0.113.50', 'client IP from X-Forwarded-For';
    is $captured_scope->{original_client}[0], '127.0.0.1', 'original client preserved';
};

subtest 'ReverseProxy - updates scheme from X-Forwarded-Proto' => sub {
    my $proxy = PAGI::Middleware::ReverseProxy->new(
        trusted_proxies => ['127.0.0.1'],
    );

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $proxy->wrap($app);
    my $scope = make_scope(
        client  => ['127.0.0.1', 12345],
        scheme  => 'http',
        headers => [['X-Forwarded-Proto', 'https']],
    );

    run_async { $wrapped->($scope, async sub { {} }, async sub { }) };

    is $captured_scope->{scheme}, 'https', 'scheme updated from header';
};

subtest 'ReverseProxy - ignores untrusted proxies' => sub {
    my $proxy = PAGI::Middleware::ReverseProxy->new(
        trusted_proxies => ['10.0.0.1'],
    );

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $proxy->wrap($app);
    my $scope = make_scope(
        client  => ['192.168.1.100', 12345],  # Not trusted
        headers => [['X-Forwarded-For', '203.0.113.50']],
    );

    run_async { $wrapped->($scope, async sub { {} }, async sub { }) };

    is $captured_scope->{client}[0], '192.168.1.100', 'client IP unchanged for untrusted proxy';
};

# ===================
# Healthcheck Middleware Tests
# ===================

subtest 'Healthcheck - returns health status' => sub {
    my $health = PAGI::Middleware::Healthcheck->new(
        path => '/health',
    );

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'App', more => 0 });
    };

    my $wrapped = $health->wrap($app);
    my $scope = make_scope(path => '/health');

    my @events;
    run_async { $wrapped->($scope, async sub { {} }, async sub  {
        my ($e) = @_; push @events, $e }) };

    is $events[0]{status}, 200, 'health check returns 200';
    my $body = JSON::PP::decode_json($events[1]{body});
    is $body->{status}, 'ok', 'status is ok';
};

subtest 'Healthcheck - passes through other paths' => sub {
    my $health = PAGI::Middleware::Healthcheck->new(
        path => '/health',
    );

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'App', more => 0 });
    };

    my $wrapped = $health->wrap($app);
    my $scope = make_scope(path => '/api');

    my @events;
    run_async { $wrapped->($scope, async sub { {} }, async sub  {
        my ($e) = @_; push @events, $e }) };

    is $events[1]{body}, 'App', 'non-health path passes through';
};

subtest 'Healthcheck - runs custom checks' => sub {
    my $health = PAGI::Middleware::Healthcheck->new(
        path => '/health',
        checks => {
            always_ok => sub { 1 },
            always_fail => sub { 0 },
        },
    );

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'App', more => 0 });
    };

    my $wrapped = $health->wrap($app);
    my $scope = make_scope(path => '/health');

    my @events;
    run_async { $wrapped->($scope, async sub { {} }, async sub  {
        my ($e) = @_; push @events, $e }) };

    is $events[0]{status}, 503, 'returns 503 when check fails';
    my $body = JSON::PP::decode_json($events[1]{body});
    is $body->{status}, 'error', 'status is error';
    is $body->{checks}{always_ok}{status}, 'ok', 'passing check reported';
    is $body->{checks}{always_fail}{status}, 'error', 'failing check reported';
};

subtest 'Healthcheck - liveness probe' => sub {
    my $health = PAGI::Middleware::Healthcheck->new(
        path => '/health',
        live_path => '/healthz',
        checks => { db => sub { die "Database down" } },
    );

    my $app = async sub { };

    my $wrapped = $health->wrap($app);
    my $scope = make_scope(path => '/healthz');

    my @events;
    run_async { $wrapped->($scope, async sub { {} }, async sub  {
        my ($e) = @_; push @events, $e }) };

    is $events[0]{status}, 200, 'liveness always returns 200';
};

done_testing;
