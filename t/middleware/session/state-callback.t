#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use PAGI::Middleware::Session::State::Callback;

# ===================
# Constructor validation
# ===================

subtest 'dies without extract callback' => sub {
    like dies { PAGI::Middleware::Session::State::Callback->new() },
        qr/extract.*required/i, 'dies without extract';
};

subtest 'dies if extract is not a CODE ref' => sub {
    like dies { PAGI::Middleware::Session::State::Callback->new(extract => 'not_code') },
        qr/extract.*CODE/i, 'dies when extract is a string';

    like dies { PAGI::Middleware::Session::State::Callback->new(extract => []) },
        qr/extract.*CODE/i, 'dies when extract is an arrayref';

    like dies { PAGI::Middleware::Session::State::Callback->new(extract => {}) },
        qr/extract.*CODE/i, 'dies when extract is a hashref';
};

# ===================
# extract
# ===================

subtest 'extract calls custom coderef and returns its value' => sub {
    my $state = PAGI::Middleware::Session::State::Callback->new(
        extract => sub { return 'custom-session-id' },
    );
    my $scope = { headers => [] };
    is $state->extract($scope), 'custom-session-id', 'returns value from coderef';
};

subtest 'extract coderef receives $scope' => sub {
    my $received_scope;
    my $state = PAGI::Middleware::Session::State::Callback->new(
        extract => sub { $received_scope = $_[0]; return 'id' },
    );
    my $scope = {
        type    => 'http',
        path    => '/test',
        headers => [['X-Custom', 'value']],
    };
    $state->extract($scope);

    is $received_scope, $scope, 'coderef receives the scope object';
};

subtest 'extract returns undef when coderef returns undef' => sub {
    my $state = PAGI::Middleware::Session::State::Callback->new(
        extract => sub { return undef },
    );
    is $state->extract({}), undef, 'returns undef from coderef';
};

# ===================
# inject
# ===================

subtest 'inject calls custom coderef' => sub {
    my $called = 0;
    my $state = PAGI::Middleware::Session::State::Callback->new(
        extract => sub { return 'id' },
        inject  => sub { $called = 1 },
    );
    my @headers = (['Content-Type', 'text/html']);
    $state->inject(\@headers, 'session123', {});

    ok $called, 'inject coderef was called';
};

subtest 'inject coderef receives ($headers, $id, $opts)' => sub {
    my @received;
    my $state = PAGI::Middleware::Session::State::Callback->new(
        extract => sub { return 'id' },
        inject  => sub { @received = @_ },
    );
    my @headers = (['Content-Type', 'text/html']);
    my $opts = { path => '/', secure => 1 };
    $state->inject(\@headers, 'sess-456', $opts);

    is $received[0], \@headers, 'receives headers arrayref';
    is $received[1], 'sess-456', 'receives session ID';
    is $received[2], $opts, 'receives options hashref';
};

subtest 'inject defaults to no-op when not provided' => sub {
    my $state = PAGI::Middleware::Session::State::Callback->new(
        extract => sub { return 'id' },
    );
    my @headers = (['Content-Type', 'text/html']);
    $state->inject(\@headers, 'session123', {});

    is scalar(@headers), 1, 'no headers added';
    is $headers[0][0], 'Content-Type', 'original header unchanged';
    is $headers[0][1], 'text/html', 'original header value unchanged';
};

done_testing;
