#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use PAGI::Context;
use PAGI::Stash;
use PAGI::Session;

subtest 'stash accessor' => sub {
    my $scope = { type => 'http', headers => [] };
    my $ctx = PAGI::Context->new($scope, sub {}, sub {});

    my $stash = $ctx->stash;
    isa_ok($stash, 'PAGI::Stash');

    # Cached — same object returned
    my $stash2 = $ctx->stash;
    ok($stash == $stash2, 'stash is cached');

    # Mutations visible through scope
    $stash->set(user => 'alice');
    is($scope->{'pagi.stash'}{user}, 'alice', 'stash writes to scope');
};

subtest 'session accessor' => sub {
    my $scope = {
        type           => 'http',
        headers        => [],
        'pagi.session' => { _id => 'sess-123', user_id => 42 },
    };
    my $ctx = PAGI::Context->new($scope, sub {}, sub {});

    my $session = $ctx->session;
    isa_ok($session, 'PAGI::Session');
    is($session->id, 'sess-123', 'session id accessible');
    is($session->get('user_id'), 42, 'session data accessible');

    # Cached
    my $session2 = $ctx->session;
    ok($session == $session2, 'session is cached');
};

subtest 'session dies without middleware' => sub {
    my $ctx = PAGI::Context->new({ type => 'http', headers => [] }, sub {}, sub {});
    ok(dies { $ctx->session }, 'session dies when pagi.session missing');
};

subtest 'has_session' => sub {
    my $ctx_no = PAGI::Context->new({ type => 'http', headers => [] }, sub {}, sub {});
    ok(!$ctx_no->has_session, 'has_session false without middleware');

    my $ctx_yes = PAGI::Context->new(
        { type => 'http', headers => [], 'pagi.session' => { _id => 'x' } },
        sub {}, sub {},
    );
    ok($ctx_yes->has_session, 'has_session true with session data');
};

subtest 'state accessor' => sub {
    my $scope = {
        type    => 'http',
        headers => [],
        state   => { db => 'connected' },
    };
    my $ctx = PAGI::Context->new($scope, sub {}, sub {});

    is($ctx->state->{db}, 'connected', 'state returns scope state');
};

subtest 'state defaults to empty hashref' => sub {
    my $ctx = PAGI::Context->new({ type => 'http', headers => [] }, sub {}, sub {});
    is($ctx->state, {}, 'state defaults to empty hashref');
};

subtest 'connection state without connection object' => sub {
    my $ctx = PAGI::Context->new({ type => 'http', headers => [] }, sub {}, sub {});

    is($ctx->connection, undef, 'connection returns undef when not set');
    is($ctx->is_connected, 0, 'is_connected returns 0 without connection');
    ok($ctx->is_disconnected, 'is_disconnected returns true without connection');
    is($ctx->disconnect_reason, undef, 'disconnect_reason returns undef');
};

subtest 'connection state with mock connection' => sub {
    my $connected = 1;
    my @callbacks;

    # Minimal duck-type mock for ConnectionState
    my $mock_conn = bless {}, 'MockConnState';
    {
        no strict 'refs';  ## no critic
        no warnings 'once';
        *MockConnState::is_connected = sub { $connected };
        *MockConnState::disconnect_reason = sub { $connected ? undef : 'client_gone' };
        *MockConnState::on_disconnect = sub { push @callbacks, $_[1] };
    }

    my $scope = {
        type               => 'http',
        headers            => [],
        'pagi.connection'  => $mock_conn,
    };
    my $ctx = PAGI::Context->new($scope, sub {}, sub {});

    ok($ctx->is_connected, 'is_connected delegates');
    ok(!$ctx->is_disconnected, 'is_disconnected delegates');
    is($ctx->disconnect_reason, undef, 'disconnect_reason undef while connected');

    $connected = 0;
    ok(!$ctx->is_connected, 'is_connected updates');
    ok($ctx->is_disconnected, 'is_disconnected updates');
    is($ctx->disconnect_reason, 'client_gone', 'disconnect_reason set');

    my $cb = sub { 'called' };
    $ctx->on_disconnect($cb);
    is(scalar @callbacks, 1, 'on_disconnect registers callback');
    is($callbacks[0], $cb, 'correct callback registered');
};

subtest 'stash shared across protocol helpers' => sub {
    my $scope = { type => 'http', method => 'GET', path => '/', headers => [] };
    my $ctx = PAGI::Context->new($scope, sub {}, sub {});

    # Set via context stash
    $ctx->stash->set(user => 'bob');

    # Verify same data visible via PAGI::Stash on raw scope
    my $direct_stash = PAGI::Stash->new($scope);
    is($direct_stash->get('user'), 'bob', 'stash data shared with direct scope access');
};

done_testing;
