#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use PAGI::Middleware::Session::State;
use PAGI::Middleware::Session::State::Cookie;

# ===================
# State base class
# ===================

subtest 'State base class - extract dies' => sub {
    my $state = PAGI::Middleware::Session::State->new();
    like dies { $state->extract({}) }, qr/must implement/, 'extract() dies with must implement';
};

subtest 'State base class - inject dies' => sub {
    my $state = PAGI::Middleware::Session::State->new();
    my @headers;
    like dies { $state->inject(\@headers, 'id123', {}) }, qr/must implement/, 'inject() dies with must implement';
};

# ===================
# State::Cookie - constructor defaults
# ===================

subtest 'State::Cookie - default cookie_name is pagi_session' => sub {
    my $state = PAGI::Middleware::Session::State::Cookie->new();
    is $state->{cookie_name}, 'pagi_session', 'default cookie_name';
};

subtest 'State::Cookie - custom cookie_name' => sub {
    my $state = PAGI::Middleware::Session::State::Cookie->new(
        cookie_name => 'my_session',
    );
    is $state->{cookie_name}, 'my_session', 'custom cookie_name';
};

# ===================
# State::Cookie - extract
# ===================

subtest 'State::Cookie - extract session ID from cookie header' => sub {
    my $state = PAGI::Middleware::Session::State::Cookie->new();
    my $scope = {
        headers => [['Cookie', 'pagi_session=abc123; other=xyz']],
    };
    is $state->extract($scope), 'abc123', 'extracts session ID';
};

subtest 'State::Cookie - extract with custom cookie_name' => sub {
    my $state = PAGI::Middleware::Session::State::Cookie->new(
        cookie_name => 'sid',
    );
    my $scope = {
        headers => [['Cookie', 'sid=def456; pagi_session=abc123']],
    };
    is $state->extract($scope), 'def456', 'extracts custom cookie name';
};

subtest 'State::Cookie - returns undef when no session cookie present' => sub {
    my $state = PAGI::Middleware::Session::State::Cookie->new();
    my $scope = {
        headers => [['Cookie', 'other=xyz; another=abc']],
    };
    is $state->extract($scope), undef, 'returns undef for missing session cookie';
};

subtest 'State::Cookie - returns undef when no cookie header at all' => sub {
    my $state = PAGI::Middleware::Session::State::Cookie->new();
    my $scope = {
        headers => [['Content-Type', 'text/html']],
    };
    is $state->extract($scope), undef, 'returns undef with no Cookie header';
};

subtest 'State::Cookie - returns undef with empty headers' => sub {
    my $state = PAGI::Middleware::Session::State::Cookie->new();
    my $scope = { headers => [] };
    is $state->extract($scope), undef, 'returns undef with empty headers';
};

subtest 'State::Cookie - extract is case-insensitive for header name' => sub {
    my $state = PAGI::Middleware::Session::State::Cookie->new();
    my $scope = {
        headers => [['cookie', 'pagi_session=lower_case']],
    };
    is $state->extract($scope), 'lower_case', 'handles lowercase cookie header';
};

# ===================
# State::Cookie - inject
# ===================

subtest 'State::Cookie - inject adds Set-Cookie header with correct format' => sub {
    my $state = PAGI::Middleware::Session::State::Cookie->new();
    my @headers;
    $state->inject(\@headers, 'session_id_value', {});

    is scalar(@headers), 1, 'one header added';
    is $headers[0][0], 'Set-Cookie', 'header name is Set-Cookie';
    like $headers[0][1], qr/pagi_session=session_id_value/, 'contains cookie name and value';
    like $headers[0][1], qr/Path=\//, 'contains Path';
    like $headers[0][1], qr/HttpOnly/, 'contains HttpOnly';
    like $headers[0][1], qr/SameSite=Lax/, 'contains SameSite=Lax';
    like $headers[0][1], qr/Max-Age=3600/, 'contains Max-Age';
};

subtest 'State::Cookie - inject includes Secure flag when configured' => sub {
    my $state = PAGI::Middleware::Session::State::Cookie->new(
        cookie_options => {
            httponly => 1,
            path     => '/',
            samesite => 'Lax',
            secure   => 1,
        },
    );
    my @headers;
    $state->inject(\@headers, 'secure_id', {});

    like $headers[0][1], qr/Secure/, 'contains Secure flag';
};

subtest 'State::Cookie - inject without Secure when not configured' => sub {
    my $state = PAGI::Middleware::Session::State::Cookie->new();
    my @headers;
    $state->inject(\@headers, 'no_secure_id', {});

    unlike $headers[0][1], qr/Secure/, 'does not contain Secure flag by default';
};

subtest 'State::Cookie - inject with custom expire' => sub {
    my $state = PAGI::Middleware::Session::State::Cookie->new(
        expire => 7200,
    );
    my @headers;
    $state->inject(\@headers, 'custom_expire_id', {});

    like $headers[0][1], qr/Max-Age=7200/, 'uses custom expire';
};

subtest 'State::Cookie - inject pushes onto existing headers' => sub {
    my $state = PAGI::Middleware::Session::State::Cookie->new();
    my @headers = (['Content-Type', 'text/html']);
    $state->inject(\@headers, 'append_id', {});

    is scalar(@headers), 2, 'header appended to existing list';
    is $headers[0][0], 'Content-Type', 'original header preserved';
    is $headers[1][0], 'Set-Cookie', 'Set-Cookie appended';
};

# ===================
# State::Cookie - clear
# ===================

subtest 'State::Cookie - clear produces Set-Cookie with Max-Age=0' => sub {
    my $state = PAGI::Middleware::Session::State::Cookie->new();
    my @headers;
    $state->clear(\@headers);

    is scalar(@headers), 1, 'one header added';
    is $headers[0][0], 'Set-Cookie', 'header name is Set-Cookie';
    like $headers[0][1], qr/pagi_session=/, 'contains cookie name';
    like $headers[0][1], qr/Max-Age=0/, 'Max-Age is 0';
    like $headers[0][1], qr/Path=\//, 'contains Path';
};

subtest 'State::Cookie - clear includes HttpOnly if configured' => sub {
    my $state = PAGI::Middleware::Session::State::Cookie->new(
        cookie_options => {
            httponly => 1,
            path     => '/app',
        },
    );
    my @headers;
    $state->clear(\@headers);

    like $headers[0][1], qr/HttpOnly/, 'contains HttpOnly';
    like $headers[0][1], qr{Path=/app}, 'uses configured path';
};

subtest 'State::Cookie - clear omits HttpOnly when not configured' => sub {
    my $state = PAGI::Middleware::Session::State::Cookie->new(
        cookie_options => {
            path => '/',
        },
    );
    my @headers;
    $state->clear(\@headers);

    unlike $headers[0][1], qr/HttpOnly/, 'no HttpOnly when not configured';
};

subtest 'State::Cookie - clear uses correct cookie name' => sub {
    my $state = PAGI::Middleware::Session::State::Cookie->new(
        cookie_name => 'my_custom_session',
    );
    my @headers;
    $state->clear(\@headers);

    like $headers[0][1], qr/my_custom_session=/, 'uses custom cookie name';
    like $headers[0][1], qr/Max-Age=0/, 'Max-Age is 0';
};

# ===================
# State base class - clear is no-op
# ===================

subtest 'State base class - clear is no-op' => sub {
    my $state = PAGI::Middleware::Session::State->new();
    my @headers;
    $state->clear(\@headers);
    is scalar(@headers), 0, 'no headers added by base clear()';
};

done_testing;
