#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;

use PAGI::Middleware::Session;
use PAGI::Middleware::Session::State::Header;
use PAGI::Middleware::Session::Store::Memory;

my $loop = IO::Async::Loop->new;

sub run_async (&) {
    my ($code) = @_;
    $loop->await($code->());
}

sub make_scope {
    my (%opts) = @_;
    return {
        type    => 'http',
        method  => $opts{method} // 'GET',
        path    => $opts{path} // '/',
        headers => $opts{headers} // [],
    };
}

# ===================
# Integration: explicit State and Store
# ===================

subtest 'new API with explicit state and store' => sub {
    PAGI::Middleware::Session::Store::Memory->clear_all();

    my $state = PAGI::Middleware::Session::State::Header->new(
        header_name => 'X-Session-ID',
    );
    my $store = PAGI::Middleware::Session::Store::Memory->new();

    my $session_mw = PAGI::Middleware::Session->new(
        secret => 'integration-secret',
        state  => $state,
        store  => $store,
    );

    # First request: create session
    my $session_id;
    my $app1 = async sub {
        my ($scope, $receive, $send) = @_;
        $session_id = $scope->{'pagi.session_id'};
        $scope->{'pagi.session'}{user_id} = 99;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    run_async { $session_mw->wrap($app1)->(make_scope(), async sub { {} }, async sub { }) };

    ok defined $session_id, 'session ID created';
    like $session_id, qr/^[a-f0-9]{64}$/, 'session ID is SHA256 hash';

    # Second request: restore session via header
    my $captured_session;
    my $app2 = async sub {
        my ($scope, $receive, $send) = @_;
        $captured_session = $scope->{'pagi.session'};
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $scope2 = make_scope(headers => [['X-Session-ID', $session_id]]);
    run_async { $session_mw->wrap($app2)->($scope2, async sub { {} }, async sub { }) };

    is $captured_session->{user_id}, 99, 'session data restored via header state';
};

# ===================
# Integration: default API still works
# ===================

subtest 'default API still works' => sub {
    PAGI::Middleware::Session->clear_sessions();

    my $session_mw = PAGI::Middleware::Session->new(secret => 'default-secret');

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $session_mw->wrap($app);
    my $scope = make_scope();

    my @events;
    my $receive = async sub { {} };
    my $send = async sub {
        my ($event) = @_; push @events, $event };

    run_async { $wrapped->($scope, $receive, $send) };

    my @set_cookies = map { $_->[1] }
        grep { lc($_->[0]) eq 'set-cookie' } @{$events[0]{headers}};
    ok scalar(@set_cookies), 'has Set-Cookie header with default config';
    like $set_cookies[0], qr/pagi_session=/, 'cookie name is pagi_session';
};

# ===================
# Integration: header state does not set cookies
# ===================

subtest 'header state does not set cookies' => sub {
    PAGI::Middleware::Session::Store::Memory->clear_all();

    my $state = PAGI::Middleware::Session::State::Header->new(
        header_name => 'X-Session-ID',
    );
    my $store = PAGI::Middleware::Session::Store::Memory->new();

    my $session_mw = PAGI::Middleware::Session->new(
        secret => 'header-secret',
        state  => $state,
        store  => $store,
    );

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $session_mw->wrap($app);
    my $scope = make_scope();

    my @events;
    my $receive = async sub { {} };
    my $send = async sub {
        my ($event) = @_; push @events, $event };

    run_async { $wrapped->($scope, $receive, $send) };

    my @set_cookies = map { $_->[1] }
        grep { lc($_->[0]) eq 'set-cookie' } @{$events[0]{headers}};
    is scalar(@set_cookies), 0, 'no Set-Cookie header when using header state';
};

# ===================
# Idempotency tests
# ===================

subtest 'idempotency: skips if session already in scope' => sub {
    PAGI::Middleware::Session->clear_sessions();

    my $session_mw = PAGI::Middleware::Session->new(secret => 'idem-secret');

    my $pre_existing_session = { user_id => 42, _id => 'pre-existing-id' };

    my $captured_scope;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $session_mw->wrap($app);

    # Pre-populate pagi.session in scope
    my $scope = make_scope();
    $scope->{'pagi.session'} = $pre_existing_session;

    my @events;
    my $receive = async sub { {} };
    my $send = async sub {
        my ($event) = @_; push @events, $event };

    run_async { $wrapped->($scope, $receive, $send) };

    # Session should be the original, not a new one
    is $captured_scope->{'pagi.session'}, $pre_existing_session,
        'outer session preserved (same reference)';
    is $captured_scope->{'pagi.session'}{user_id}, 42,
        'outer session data intact';

    # No Set-Cookie should be added
    my @set_cookies = map { $_->[1] }
        grep { lc($_->[0]) eq 'set-cookie' } @{$events[0]{headers}};
    is scalar(@set_cookies), 0, 'no Set-Cookie added when session already exists';
};

subtest 'idempotency: normal behavior when no pre-existing session' => sub {
    PAGI::Middleware::Session->clear_sessions();

    my $session_mw = PAGI::Middleware::Session->new(secret => 'idem-secret-2');

    my $captured_scope;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $session_mw->wrap($app);
    my $scope = make_scope();

    my @events;
    my $receive = async sub { {} };
    my $send = async sub {
        my ($event) = @_; push @events, $event };

    run_async { $wrapped->($scope, $receive, $send) };

    ok exists $captured_scope->{'pagi.session'}, 'session created when none pre-exists';
    ok exists $captured_scope->{'pagi.session_id'}, 'session_id set';
    like $captured_scope->{'pagi.session_id'}, qr/^[a-f0-9]{64}$/, 'valid session ID format';

    my @set_cookies = map { $_->[1] }
        grep { lc($_->[0]) eq 'set-cookie' } @{$events[0]{headers}};
    ok scalar(@set_cookies), 'Set-Cookie header added for new session';
};

# ===================
# Integration: destroy deletes session and clears cookie
# ===================

subtest 'destroy deletes session and clears cookie' => sub {
    PAGI::Middleware::Session::Store::Memory->clear_all;
    my $session_mw = PAGI::Middleware::Session->new(secret => 'test-secret');

    # Create a session first
    my $session_id;
    my $app1 = async sub {
        my ($scope, $receive, $send) = @_;
        $session_id = $scope->{'pagi.session_id'};
        $scope->{'pagi.session'}{user_id} = 42;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };
    run_async { $session_mw->wrap($app1)->(make_scope(), async sub { {} }, async sub { }) };

    # Now destroy it
    my $app2 = async sub {
        my ($scope, $receive, $send) = @_;
        $scope->{'pagi.session'}{_destroyed} = 1;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my @events;
    my $scope2 = make_scope(headers => [['Cookie', "pagi_session=$session_id"]]);
    run_async {
        $session_mw->wrap($app2)->($scope2, async sub { {} }, async sub { push @events, $_[0] })
    };

    # Should have a Set-Cookie with Max-Age=0
    my @cookies = map { $_->[1] } grep { lc($_->[0]) eq 'set-cookie' } @{$events[0]{headers}};
    ok(scalar @cookies, 'has Set-Cookie header');
    like($cookies[0], qr/Max-Age=0/, 'cookie expired');

    # Session should be gone from store
    my $app3 = async sub {
        my ($scope, $receive, $send) = @_;
        # Session should NOT be restored — it was destroyed
        ok(!exists $scope->{'pagi.session'}{user_id}, 'session data gone after destroy');
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };
    my $scope3 = make_scope(headers => [['Cookie', "pagi_session=$session_id"]]);
    run_async { $session_mw->wrap($app3)->($scope3, async sub { {} }, async sub { }) };
};

# ===================
# Integration: regenerate creates new session ID and deletes old
# ===================

subtest 'regenerate creates new session ID and deletes old' => sub {
    PAGI::Middleware::Session::Store::Memory->clear_all;
    my $session_mw = PAGI::Middleware::Session->new(secret => 'test-secret');

    # Create a session
    my $old_id;
    my $app1 = async sub {
        my ($scope, $receive, $send) = @_;
        $old_id = $scope->{'pagi.session_id'};
        $scope->{'pagi.session'}{user_id} = 42;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };
    run_async { $session_mw->wrap($app1)->(make_scope(), async sub { {} }, async sub { }) };

    # Regenerate the session ID (simulates post-login)
    my $new_id;
    my $app2 = async sub {
        my ($scope, $receive, $send) = @_;
        $scope->{'pagi.session'}{_regenerated} = 1;
        $scope->{'pagi.session'}{logged_in} = 1;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my @events;
    my $scope2 = make_scope(headers => [['Cookie', "pagi_session=$old_id"]]);
    run_async {
        $session_mw->wrap($app2)->($scope2, async sub { {} }, async sub { push @events, $_[0] })
    };

    # Extract new session ID from Set-Cookie
    my @cookies = map { $_->[1] } grep { lc($_->[0]) eq 'set-cookie' } @{$events[0]{headers}};
    ok(scalar @cookies, 'has Set-Cookie header after regenerate');
    ($new_id) = $cookies[0] =~ /pagi_session=([a-f0-9]+)/;
    ok($new_id, 'new session ID in cookie');
    isnt($new_id, $old_id, 'new ID differs from old ID');

    # Old session ID should not load data
    my $captured_session;
    my $app3 = async sub {
        my ($scope, $receive, $send) = @_;
        $captured_session = $scope->{'pagi.session'};
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };
    my $scope3 = make_scope(headers => [['Cookie', "pagi_session=$old_id"]]);
    run_async { $session_mw->wrap($app3)->($scope3, async sub { {} }, async sub { }) };
    ok(!$captured_session->{user_id}, 'old session ID returns no data');

    # New session ID should have the data
    my $scope4 = make_scope(headers => [['Cookie', "pagi_session=$new_id"]]);
    run_async { $session_mw->wrap($app3)->($scope4, async sub { {} }, async sub { }) };
    is($captured_session->{user_id}, 42, 'data preserved under new ID');
    is($captured_session->{logged_in}, 1, 'new data also present');
};

done_testing;
