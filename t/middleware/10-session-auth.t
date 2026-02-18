#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;
use MIME::Base64 qw(encode_base64);
use JSON::MaybeXS;
use Digest::SHA qw(hmac_sha256);

use PAGI::Middleware::Cookie;
use PAGI::Middleware::Session;
use PAGI::Middleware::Auth::Basic;
use PAGI::Middleware::Auth::Bearer;

my $loop = IO::Async::Loop->new;

sub make_scope {
    my (%opts) = @_;
    return {
        type    => 'http',
        method  => $opts{method} // 'GET',
        path    => $opts{path} // '/',
        headers => $opts{headers} // [],
    };
}

sub run_async (&) {
    my ($code) = @_;
    $loop->await($code->());
}

# ===================
# Cookie Middleware Tests
# ===================

subtest 'Cookie middleware - parses cookies' => sub {
    my $cookie = PAGI::Middleware::Cookie->new();

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $cookie->wrap($app);
    my $scope = make_scope(headers => [['Cookie', 'session=abc123; user=john']]);

    my $receive = async sub { {} };
    my $send = async sub { };

    run_async { $wrapped->($scope, $receive, $send) };

    ok exists $captured_scope->{'pagi.cookies'}, 'has cookies in scope';
    is $captured_scope->{'pagi.cookies'}{session}, 'abc123', 'session cookie parsed';
    is $captured_scope->{'pagi.cookies'}{user}, 'john', 'user cookie parsed';
};

subtest 'Cookie middleware - cookie jar sets response cookies' => sub {
    my $cookie = PAGI::Middleware::Cookie->new();

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $scope->{'pagi.cookie_jar'}->set('token', 'xyz789', httponly => 1, secure => 1);
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $cookie->wrap($app);
    my $scope = make_scope();

    my @events;
    my $receive = async sub { {} };
    my $send = async sub  {
        my ($event) = @_; push @events, $event };

    run_async { $wrapped->($scope, $receive, $send) };

    my %headers = map { lc($_->[0]) => $_->[1] } @{$events[0]{headers}};
    ok exists $headers{'set-cookie'}, 'has Set-Cookie header';
    like $headers{'set-cookie'}, qr/token=xyz789/, 'cookie value set';
    like $headers{'set-cookie'}, qr/HttpOnly/i, 'HttpOnly flag set';
    like $headers{'set-cookie'}, qr/Secure/i, 'Secure flag set';
};

# ===================
# Session Middleware Tests
# ===================

subtest 'Session middleware - creates new session' => sub {
    PAGI::Middleware::Session->clear_sessions();

    my $session = PAGI::Middleware::Session->new(secret => 'test-secret');

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        $scope->{'pagi.session'}{user_id} = 42;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $session->wrap($app);
    my $scope = make_scope();

    my @events;
    my $receive = async sub { {} };
    my $send = async sub  {
        my ($event) = @_; push @events, $event };

    run_async { $wrapped->($scope, $receive, $send) };

    ok exists $captured_scope->{'pagi.session'}, 'has session in scope';
    ok exists $captured_scope->{'pagi.session_id'}, 'has session_id';
    like $captured_scope->{'pagi.session_id'}, qr/^[a-f0-9]{64}$/, 'session ID is SHA256 hash';

    my %headers = map { lc($_->[0]) => $_->[1] } @{$events[0]{headers}};
    ok exists $headers{'set-cookie'}, 'has Set-Cookie header for new session';
};

subtest 'Session middleware - restores existing session' => sub {
    PAGI::Middleware::Session->clear_sessions();

    my $session_mw = PAGI::Middleware::Session->new(secret => 'test-secret');

    # First request - create session
    my $session_id;
    my $app1 = async sub  {
        my ($scope, $receive, $send) = @_;
        $session_id = $scope->{'pagi.session_id'};
        $scope->{'pagi.session'}{counter} = 1;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    run_async { $session_mw->wrap($app1)->(make_scope(), async sub { {} }, async sub { }) };

    # Second request - restore session
    my $captured_session;
    my $app2 = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_session = $scope->{'pagi.session'};
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $scope2 = make_scope(headers => [['Cookie', "pagi_session=$session_id"]]);
    run_async { $session_mw->wrap($app2)->($scope2, async sub { {} }, async sub { }) };

    is $captured_session->{counter}, 1, 'session data restored';
};

# ===================
# Auth::Basic Middleware Tests
# ===================

subtest 'Auth::Basic - returns 401 without credentials' => sub {
    my $auth = PAGI::Middleware::Auth::Basic->new(
        realm => 'Test',
        authenticator => sub { 1 },
    );

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $auth->wrap($app);
    my $scope = make_scope();

    my @events;
    my $receive = async sub { {} };
    my $send = async sub  {
        my ($event) = @_; push @events, $event };

    run_async { $wrapped->($scope, $receive, $send) };

    is $events[0]{status}, 401, 'returns 401 Unauthorized';
    my %headers = map { lc($_->[0]) => $_->[1] } @{$events[0]{headers}};
    like $headers{'www-authenticate'}, qr/Basic realm="Test"/, 'has WWW-Authenticate header';
};

subtest 'Auth::Basic - accepts valid credentials' => sub {
    my $auth = PAGI::Middleware::Auth::Basic->new(
        authenticator => sub  {
        my ($user, $pass) = @_;
            return $user eq 'admin' && $pass eq 'secret';
        },
    );

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $auth->wrap($app);
    my $credentials = encode_base64('admin:secret', '');
    my $scope = make_scope(headers => [['Authorization', "Basic $credentials"]]);

    my @events;
    run_async { $wrapped->($scope, async sub { {} }, async sub  {
        my ($e) = @_; push @events, $e }) };

    is $events[0]{status}, 200, 'request succeeds';
    is $captured_scope->{'pagi.auth'}{username}, 'admin', 'username in scope';
};

subtest 'Auth::Basic - rejects invalid credentials' => sub {
    my $auth = PAGI::Middleware::Auth::Basic->new(
        authenticator => sub  {
        my ($user, $pass) = @_;
            return $user eq 'admin' && $pass eq 'secret';
        },
    );

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $auth->wrap($app);
    my $credentials = encode_base64('admin:wrong', '');
    my $scope = make_scope(headers => [['Authorization', "Basic $credentials"]]);

    my @events;
    run_async { $wrapped->($scope, async sub { {} }, async sub  {
        my ($e) = @_; push @events, $e }) };

    is $events[0]{status}, 401, 'returns 401 for wrong password';
};

# ===================
# Auth::Bearer Middleware Tests
# ===================

sub make_jwt {
    my ($claims, $secret) = @_;
    my $header = encode_json({ alg => 'HS256', typ => 'JWT' });
    my $payload = encode_json($claims);

    my $header_b64 = _base64url_encode($header);
    my $payload_b64 = _base64url_encode($payload);
    my $signature = _base64url_encode(hmac_sha256("$header_b64.$payload_b64", $secret));

    return "$header_b64.$payload_b64.$signature";
}

sub _base64url_encode {
    my $data = shift;
    my $encoded = MIME::Base64::encode_base64($data, '');
    $encoded =~ tr{+/}{-_};
    $encoded =~ s/=+$//;
    return $encoded;
}

subtest 'Auth::Bearer - returns 401 without token' => sub {
    my $auth = PAGI::Middleware::Auth::Bearer->new(secret => 'test-secret');

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $auth->wrap($app);
    my $scope = make_scope();

    my @events;
    run_async { $wrapped->($scope, async sub { {} }, async sub  {
        my ($e) = @_; push @events, $e }) };

    is $events[0]{status}, 401, 'returns 401 without token';
};

subtest 'Auth::Bearer - accepts valid JWT' => sub {
    my $secret = 'jwt-secret-key';
    my $auth = PAGI::Middleware::Auth::Bearer->new(secret => $secret);

    my $token = make_jwt({ sub => 'user123', exp => time() + 3600 }, $secret);

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $auth->wrap($app);
    my $scope = make_scope(headers => [['Authorization', "Bearer $token"]]);

    my @events;
    run_async { $wrapped->($scope, async sub { {} }, async sub  {
        my ($e) = @_; push @events, $e }) };

    is $events[0]{status}, 200, 'request succeeds';
    is $captured_scope->{'pagi.auth'}{claims}{sub}, 'user123', 'JWT claims in scope';
};

subtest 'Auth::Bearer - rejects expired JWT' => sub {
    my $secret = 'jwt-secret-key';
    my $auth = PAGI::Middleware::Auth::Bearer->new(secret => $secret);

    my $token = make_jwt({ sub => 'user123', exp => time() - 3600 }, $secret);

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $auth->wrap($app);
    my $scope = make_scope(headers => [['Authorization', "Bearer $token"]]);

    my @events;
    run_async { $wrapped->($scope, async sub { {} }, async sub  {
        my ($e) = @_; push @events, $e }) };

    is $events[0]{status}, 401, 'rejects expired token';
};

subtest 'Auth::Bearer - rejects invalid signature' => sub {
    my $auth = PAGI::Middleware::Auth::Bearer->new(secret => 'correct-secret');

    my $token = make_jwt({ sub => 'user123' }, 'wrong-secret');

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $auth->wrap($app);
    my $scope = make_scope(headers => [['Authorization', "Bearer $token"]]);

    my @events;
    run_async { $wrapped->($scope, async sub { {} }, async sub  {
        my ($e) = @_; push @events, $e }) };

    is $events[0]{status}, 401, 'rejects invalid signature';
};

# ===================
# Session Cookie SameSite Tests
# ===================

subtest 'Session middleware - default cookie includes SameSite=Lax' => sub {
    PAGI::Middleware::Session->clear_sessions();

    my $session = PAGI::Middleware::Session->new(secret => 'test-secret');

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $session->wrap($app);
    my $scope = make_scope();

    my @events;
    my $receive = async sub { {} };
    my $send = async sub {
        my ($event) = @_; push @events, $event };

    run_async { $wrapped->($scope, $receive, $send) };

    my @set_cookies = map { $_->[1] }
        grep { lc($_->[0]) eq 'set-cookie' } @{$events[0]{headers}};
    ok scalar(@set_cookies), 'has Set-Cookie header';
    like $set_cookies[0], qr/SameSite=Lax/, 'default cookie includes SameSite=Lax';
};

subtest 'Session middleware - custom samesite overrides default' => sub {
    PAGI::Middleware::Session->clear_sessions();

    my $session = PAGI::Middleware::Session->new(
        secret => 'test-secret',
        cookie_options => {
            httponly => 1,
            path     => '/',
            samesite => 'Strict',
        },
    );

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $session->wrap($app);
    my $scope = make_scope();

    my @events;
    my $receive = async sub { {} };
    my $send = async sub {
        my ($event) = @_; push @events, $event };

    run_async { $wrapped->($scope, $receive, $send) };

    my @set_cookies = map { $_->[1] }
        grep { lc($_->[0]) eq 'set-cookie' } @{$events[0]{headers}};
    ok scalar(@set_cookies), 'has Set-Cookie header';
    like $set_cookies[0], qr/SameSite=Strict/, 'custom samesite=Strict is used';
    unlike $set_cookies[0], qr/SameSite=Lax/, 'default Lax is not present';
};

done_testing;
