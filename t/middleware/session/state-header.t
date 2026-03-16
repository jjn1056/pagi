#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use PAGI::Middleware::Session::State::Header;
use PAGI::Middleware::Session::State::Bearer;

# ===================
# State::Header - constructor
# ===================

subtest 'State::Header - dies without header_name' => sub {
    like dies { PAGI::Middleware::Session::State::Header->new() },
        qr/header_name is required/, 'dies without header_name';
};

# ===================
# State::Header - extract
# ===================

subtest 'State::Header - extracts from custom header' => sub {
    my $state = PAGI::Middleware::Session::State::Header->new(
        header_name => 'X-Session-ID',
    );
    my $scope = {
        headers => [['X-Session-ID', 'abc123']],
    };
    is $state->extract($scope), 'abc123', 'extracts session ID from custom header';
};

subtest 'State::Header - case-insensitive header matching' => sub {
    my $state = PAGI::Middleware::Session::State::Header->new(
        header_name => 'X-Session-ID',
    );
    my $scope = {
        headers => [['x-session-id', 'lower_case_value']],
    };
    is $state->extract($scope), 'lower_case_value', 'matches header case-insensitively';
};

subtest 'State::Header - returns undef when header missing' => sub {
    my $state = PAGI::Middleware::Session::State::Header->new(
        header_name => 'X-Session-ID',
    );
    my $scope = {
        headers => [['Content-Type', 'text/html']],
    };
    is $state->extract($scope), undef, 'returns undef for missing header';
};

subtest 'State::Header - returns undef with empty headers' => sub {
    my $state = PAGI::Middleware::Session::State::Header->new(
        header_name => 'X-Session-ID',
    );
    my $scope = { headers => [] };
    is $state->extract($scope), undef, 'returns undef with empty headers';
};

subtest 'State::Header - extract with pattern' => sub {
    my $state = PAGI::Middleware::Session::State::Header->new(
        header_name => 'X-Auth-Token',
        pattern     => qr/^Token\s+(.+)$/i,
    );
    my $scope = {
        headers => [['X-Auth-Token', 'Token my-session-id']],
    };
    is $state->extract($scope), 'my-session-id', 'extracts value via pattern capture';
};

subtest 'State::Header - pattern that does not match returns undef' => sub {
    my $state = PAGI::Middleware::Session::State::Header->new(
        header_name => 'X-Auth-Token',
        pattern     => qr/^Token\s+(.+)$/i,
    );
    my $scope = {
        headers => [['X-Auth-Token', 'Basic credentials']],
    };
    is $state->extract($scope), undef, 'returns undef when pattern does not match';
};

# ===================
# State::Header - inject (no-op)
# ===================

subtest 'State::Header - inject is no-op' => sub {
    my $state = PAGI::Middleware::Session::State::Header->new(
        header_name => 'X-Session-ID',
    );
    my @headers = (['Content-Type', 'text/html']);
    $state->inject(\@headers, 'session123', {});

    is scalar(@headers), 1, 'no headers added';
    is $headers[0][0], 'Content-Type', 'original header unchanged';
    is $headers[0][1], 'text/html', 'original header value unchanged';
};

# ===================
# State::Bearer - extract
# ===================

subtest 'State::Bearer - extracts opaque token from Authorization Bearer' => sub {
    my $state = PAGI::Middleware::Session::State::Bearer->new();
    my $scope = {
        headers => [['Authorization', 'Bearer my-token']],
    };
    is $state->extract($scope), 'my-token', 'extracts bearer token';
};

subtest 'State::Bearer - returns undef for non-bearer auth' => sub {
    my $state = PAGI::Middleware::Session::State::Bearer->new();
    my $scope = {
        headers => [['Authorization', 'Basic dXNlcjpwYXNz']],
    };
    is $state->extract($scope), undef, 'returns undef for Basic auth';
};

subtest 'State::Bearer - returns undef when no Authorization header' => sub {
    my $state = PAGI::Middleware::Session::State::Bearer->new();
    my $scope = {
        headers => [['Content-Type', 'application/json']],
    };
    is $state->extract($scope), undef, 'returns undef with no Authorization header';
};

# ===================
# State::Bearer - inject (no-op, inherited)
# ===================

subtest 'State::Bearer - inject is no-op' => sub {
    my $state = PAGI::Middleware::Session::State::Bearer->new();
    my @headers = (['Content-Type', 'application/json']);
    $state->inject(\@headers, 'token123', {});

    is scalar(@headers), 1, 'no headers added';
    is $headers[0][0], 'Content-Type', 'original header unchanged';
};

done_testing;
