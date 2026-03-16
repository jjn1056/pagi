#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use PAGI::Session;

# ===================
# set and get round-trip
# ===================

subtest 'set and get round-trip' => sub {
    my $session = PAGI::Session->new({});
    $session->set('user_id', 42);
    is $session->get('user_id'), 42, 'get returns value that was set';

    $session->set('name', 'Alice');
    is $session->get('name'), 'Alice', 'get returns string value';
};

# ===================
# get dies on missing key (typo protection)
# ===================

subtest 'get dies on missing key' => sub {
    my $session = PAGI::Session->new({});
    my $err = dies { $session->get('nonexistent') };
    ok $err, 'get dies when key does not exist';
};

# ===================
# get error message includes key name
# ===================

subtest 'get error message includes key name' => sub {
    my $session = PAGI::Session->new({});
    like dies { $session->get('typo_key') },
        qr/typo_key/, 'error message includes the missing key name';
};

# ===================
# get with default undef returns undef for missing key
# ===================

subtest 'get with default undef returns undef for missing key' => sub {
    my $session = PAGI::Session->new({});
    my $result = $session->get('missing', undef);
    is $result, undef, 'returns undef default for missing key';
};

# ===================
# get with default 0 returns 0 for missing key
# ===================

subtest 'get with default 0 returns 0 for missing key' => sub {
    my $session = PAGI::Session->new({});
    my $result = $session->get('missing', 0);
    is $result, 0, 'returns 0 default for missing key';
};

# ===================
# get with default "fallback" returns "fallback" for missing key
# ===================

subtest 'get with default fallback returns fallback for missing key' => sub {
    my $session = PAGI::Session->new({});
    my $result = $session->get('missing', 'fallback');
    is $result, 'fallback', 'returns string default for missing key';
};

# ===================
# get with default still returns real value when key exists
# ===================

subtest 'get with default returns real value when key exists' => sub {
    my $session = PAGI::Session->new({});
    $session->set('color', 'blue');
    my $result = $session->get('color', 'red');
    is $result, 'blue', 'returns actual value, not the default';
};

# ===================
# id accessor
# ===================

subtest 'id accessor' => sub {
    my $session = PAGI::Session->new({ _id => 'abc123' });
    is $session->id, 'abc123', 'id returns _id from data';
};

# ===================
# regenerate sets _regenerated flag
# ===================

subtest 'regenerate sets _regenerated flag' => sub {
    my $data = {};
    my $session = PAGI::Session->new($data);
    $session->regenerate;
    is $data->{_regenerated}, 1, 'regenerate sets _regenerated = 1 in data';
};

# ===================
# destroy sets _destroyed flag
# ===================

subtest 'destroy sets _destroyed flag' => sub {
    my $data = {};
    my $session = PAGI::Session->new($data);
    $session->destroy;
    is $data->{_destroyed}, 1, 'destroy sets _destroyed = 1 in data';
};

# ===================
# exists checks key presence
# ===================

subtest 'exists checks key presence' => sub {
    my $session = PAGI::Session->new({});
    ok !$session->exists('nope'), 'exists returns false for missing key';

    $session->set('present', 'yes');
    ok $session->exists('present'), 'exists returns true for present key';
};

# ===================
# delete removes key
# ===================

subtest 'delete removes key' => sub {
    my $session = PAGI::Session->new({});
    $session->set('temp', 'value');
    ok $session->exists('temp'), 'key exists before delete';

    $session->delete('temp');
    ok !$session->exists('temp'), 'key gone after delete';
};

# ===================
# keys returns only non-underscore-prefixed keys
# ===================

subtest 'keys returns only user keys' => sub {
    my $data = {
        _id          => 'sess123',
        _created     => 1000,
        _last_access => 2000,
        user_id      => 42,
        name         => 'Alice',
        role         => 'admin',
    };
    my $session = PAGI::Session->new($data);
    my @keys = sort $session->keys;
    is \@keys, [qw(name role user_id)], 'keys filters out underscore-prefixed internal keys';
};

# ===================
# construct from scope data
# ===================

subtest 'construct from scope data' => sub {
    my $scope = {
        type => 'http',
        'pagi.session' => {
            _id          => 'scope-sess-1',
            _created     => 1700000000,
            _last_access => 1700000100,
            username     => 'bob',
            role         => 'user',
        },
    };

    my $session = PAGI::Session->new($scope->{'pagi.session'});
    is $session->id, 'scope-sess-1', 'id from scope session data';
    is $session->get('username'), 'bob', 'get username from scope session';
    is $session->get('role'), 'user', 'get role from scope session';

    my @keys = sort $session->keys;
    is \@keys, [qw(role username)], 'keys from scope session filters internals';
};

# ===================
# Constructor flexibility
# ===================

subtest 'construct from scope hashref' => sub {
    my $scope = {
        type => 'http',
        'pagi.session' => { _id => 'from-scope', counter => 7 },
    };
    my $session = PAGI::Session->new($scope);
    is($session->id, 'from-scope', 'id from scope');
    is($session->get('counter'), 7, 'data from scope');

    # Mutations visible in original scope
    $session->set('added', 1);
    is($scope->{'pagi.session'}{added}, 1, 'mutation visible in scope');
};

subtest 'construct from object with ->scope (duck typing)' => sub {
    # Simulate a PAGI::Request-like object
    my $fake_req = bless {
        _scope => {
            type => 'http',
            'pagi.session' => { _id => 'from-req', user_id => 42 },
        },
    }, 'FakeRequest';

    my $session = PAGI::Session->new($fake_req);
    is($session->id, 'from-req', 'id from request-like object');
    is($session->get('user_id'), 42, 'data from request-like object');
};

subtest 'dies on invalid argument' => sub {
    ok(dies { PAGI::Session->new("string") }, 'dies on string');
    ok(dies { PAGI::Session->new(undef) }, 'dies on undef');
    ok(dies { PAGI::Session->new(42) }, 'dies on number');
    like(dies { PAGI::Session->new("bad") }, qr/requires session data/, 'error message');
};

# Fake request class for duck-typing test
package FakeRequest;
sub scope { shift->{_scope} }

package main;

done_testing;
