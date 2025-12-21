#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);

use PAGI::Middleware::GZip;
use PAGI::Middleware::ETag;
use PAGI::Middleware::ConditionalGet;

my $loop = IO::Async::Loop->new;

# Helper to create HTTP scope
sub make_scope {
    my (%opts) = @_;
    return {
        type    => 'http',
        method  => $opts{method} // 'GET',
        path    => '/',
        headers => $opts{headers} // [],
    };
}

# Helper to run async tests
sub run_async :prototype(&) {
    my ($code) = @_;
    $loop->await($code->());
}

# ===================
# GZip Middleware Tests
# ===================

subtest 'GZip middleware - compresses when client accepts' => sub {
    my $gzip = PAGI::Middleware::GZip->new(min_size => 10);

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['Content-Type', 'text/html']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'Hello World! This is a longer response body.',
            more => 0,
        });
    };

    my $wrapped = $gzip->wrap($app);
    my $scope = make_scope(headers => [['Accept-Encoding', 'gzip, deflate']]);

    my @events;
    my $send = async sub  {
        my ($event) = @_; push @events, $event };
    my $receive = async sub { { type => 'http.request', body => '', more => 0 } };

    run_async { $wrapped->($scope, $receive, $send) };

    is scalar(@events), 2, 'got 2 events';
    is $events[0]{status}, 200, 'status is 200';

    # Check for gzip headers
    my %headers = map { lc($_->[0]) => $_->[1] } @{$events[0]{headers}};
    is $headers{'content-encoding'}, 'gzip', 'has Content-Encoding: gzip';
    ok exists $headers{'vary'}, 'has Vary header';

    # Decompress and verify
    my $compressed = $events[1]{body};
    my $decompressed;
    gunzip(\$compressed, \$decompressed) or die "gunzip failed: $GunzipError";
    is $decompressed, 'Hello World! This is a longer response body.', 'body decompresses correctly';
};

subtest 'GZip middleware - skips when client does not accept gzip' => sub {
    my $gzip = PAGI::Middleware::GZip->new(min_size => 10);

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['Content-Type', 'text/html']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'Hello World! This is a longer response body.',
            more => 0,
        });
    };

    my $wrapped = $gzip->wrap($app);
    my $scope = make_scope(headers => []);  # No Accept-Encoding

    my @events;
    my $send = async sub  {
        my ($event) = @_; push @events, $event };
    my $receive = async sub { { type => 'http.request', body => '', more => 0 } };

    run_async { $wrapped->($scope, $receive, $send) };

    my %headers = map { lc($_->[0]) => $_->[1] } @{$events[0]{headers}};
    ok !exists $headers{'content-encoding'}, 'no Content-Encoding header';
    is $events[1]{body}, 'Hello World! This is a longer response body.', 'body unchanged';
};

subtest 'GZip middleware - skips small responses' => sub {
    my $gzip = PAGI::Middleware::GZip->new(min_size => 1000);

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['Content-Type', 'text/html']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'Small',
            more => 0,
        });
    };

    my $wrapped = $gzip->wrap($app);
    my $scope = make_scope(headers => [['Accept-Encoding', 'gzip']]);

    my @events;
    my $send = async sub  {
        my ($event) = @_; push @events, $event };
    my $receive = async sub { { type => 'http.request', body => '', more => 0 } };

    run_async { $wrapped->($scope, $receive, $send) };

    my %headers = map { lc($_->[0]) => $_->[1] } @{$events[0]{headers}};
    ok !exists $headers{'content-encoding'}, 'no compression for small body';
    is $events[1]{body}, 'Small', 'body unchanged';
};

# ===================
# ETag Middleware Tests
# ===================

subtest 'ETag middleware - generates ETag' => sub {
    my $etag = PAGI::Middleware::ETag->new();

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['Content-Type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'Hello World',
            more => 0,
        });
    };

    my $wrapped = $etag->wrap($app);
    my $scope = make_scope();

    my @events;
    my $send = async sub  {
        my ($event) = @_; push @events, $event };
    my $receive = async sub { { type => 'http.request', body => '', more => 0 } };

    run_async { $wrapped->($scope, $receive, $send) };

    my %headers = map { lc($_->[0]) => $_->[1] } @{$events[0]{headers}};
    ok exists $headers{etag}, 'has ETag header';
    like $headers{etag}, qr/^"[a-f0-9]{32}"$/, 'ETag is MD5 hash format';
};

subtest 'ETag middleware - generates weak ETag' => sub {
    my $etag = PAGI::Middleware::ETag->new(weak => 1);

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['Content-Type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'Hello World',
            more => 0,
        });
    };

    my $wrapped = $etag->wrap($app);
    my $scope = make_scope();

    my @events;
    my $send = async sub  {
        my ($event) = @_; push @events, $event };
    my $receive = async sub { { type => 'http.request', body => '', more => 0 } };

    run_async { $wrapped->($scope, $receive, $send) };

    my %headers = map { lc($_->[0]) => $_->[1] } @{$events[0]{headers}};
    like $headers{etag}, qr{^W/"[a-f0-9]{32}"$}, 'ETag has weak prefix';
};

subtest 'ETag middleware - preserves existing ETag' => sub {
    my $etag = PAGI::Middleware::ETag->new();

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['Content-Type', 'text/plain'], ['ETag', '"existing"']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'Hello World',
            more => 0,
        });
    };

    my $wrapped = $etag->wrap($app);
    my $scope = make_scope();

    my @events;
    my $send = async sub  {
        my ($event) = @_; push @events, $event };
    my $receive = async sub { { type => 'http.request', body => '', more => 0 } };

    run_async { $wrapped->($scope, $receive, $send) };

    my %headers = map { lc($_->[0]) => $_->[1] } @{$events[0]{headers}};
    is $headers{etag}, '"existing"', 'existing ETag preserved';
};

# ===================
# ConditionalGet Middleware Tests
# ===================

subtest 'ConditionalGet - returns 304 on ETag match' => sub {
    my $cond = PAGI::Middleware::ConditionalGet->new();

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['Content-Type', 'text/plain'], ['ETag', '"abc123"']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'Hello World',
            more => 0,
        });
    };

    my $wrapped = $cond->wrap($app);
    my $scope = make_scope(headers => [['If-None-Match', '"abc123"']]);

    my @events;
    my $send = async sub  {
        my ($event) = @_; push @events, $event };
    my $receive = async sub { { type => 'http.request', body => '', more => 0 } };

    run_async { $wrapped->($scope, $receive, $send) };

    is $events[0]{status}, 304, 'returns 304 Not Modified';
    is $events[1]{body}, '', 'body is empty';
};

subtest 'ConditionalGet - returns 200 on ETag mismatch' => sub {
    my $cond = PAGI::Middleware::ConditionalGet->new();

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['Content-Type', 'text/plain'], ['ETag', '"abc123"']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'Hello World',
            more => 0,
        });
    };

    my $wrapped = $cond->wrap($app);
    my $scope = make_scope(headers => [['If-None-Match', '"different"']]);

    my @events;
    my $send = async sub  {
        my ($event) = @_; push @events, $event };
    my $receive = async sub { { type => 'http.request', body => '', more => 0 } };

    run_async { $wrapped->($scope, $receive, $send) };

    is $events[0]{status}, 200, 'returns 200 OK';
    is $events[1]{body}, 'Hello World', 'body included';
};

subtest 'ConditionalGet - handles wildcard If-None-Match' => sub {
    my $cond = PAGI::Middleware::ConditionalGet->new();

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['Content-Type', 'text/plain'], ['ETag', '"anything"']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'Hello World',
            more => 0,
        });
    };

    my $wrapped = $cond->wrap($app);
    my $scope = make_scope(headers => [['If-None-Match', '*']]);

    my @events;
    my $send = async sub  {
        my ($event) = @_; push @events, $event };
    my $receive = async sub { { type => 'http.request', body => '', more => 0 } };

    run_async { $wrapped->($scope, $receive, $send) };

    is $events[0]{status}, 304, '* matches any ETag';
};

subtest 'ConditionalGet - ignores POST requests' => sub {
    my $cond = PAGI::Middleware::ConditionalGet->new();

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['Content-Type', 'text/plain'], ['ETag', '"abc123"']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'Created',
            more => 0,
        });
    };

    my $wrapped = $cond->wrap($app);
    my $scope = make_scope(
        method  => 'POST',
        headers => [['If-None-Match', '"abc123"']]
    );

    my @events;
    my $send = async sub  {
        my ($event) = @_; push @events, $event };
    my $receive = async sub { { type => 'http.request', body => '', more => 0 } };

    run_async { $wrapped->($scope, $receive, $send) };

    is $events[0]{status}, 200, 'POST request returns full response';
};

done_testing;
