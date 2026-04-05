#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use PAGI::Session;

# ===================
# set and get round-trip
# ===================

subtest 'set and get round-trip' => sub {
    my $session = PAGI::Session->from_data({});
    $session->set('user_id', 42);
    is $session->get('user_id'), 42, 'get returns value that was set';

    $session->set('name', 'Alice');
    is $session->get('name'), 'Alice', 'get returns string value';
};

# ===================
# get dies on missing key (typo protection)
# ===================

subtest 'get dies on missing key' => sub {
    my $session = PAGI::Session->from_data({});
    my $err = dies { $session->get('nonexistent') };
    ok $err, 'get dies when key does not exist';
};

# ===================
# get error message includes key name
# ===================

subtest 'get error message includes key name' => sub {
    my $session = PAGI::Session->from_data({});
    like dies { $session->get('typo_key') },
        qr/typo_key/, 'error message includes the missing key name';
};

# ===================
# get with default undef returns undef for missing key
# ===================

subtest 'get with default undef returns undef for missing key' => sub {
    my $session = PAGI::Session->from_data({});
    my $result = $session->get('missing', undef);
    is $result, undef, 'returns undef default for missing key';
};

# ===================
# get with default 0 returns 0 for missing key
# ===================

subtest 'get with default 0 returns 0 for missing key' => sub {
    my $session = PAGI::Session->from_data({});
    my $result = $session->get('missing', 0);
    is $result, 0, 'returns 0 default for missing key';
};

# ===================
# get with default "fallback" returns "fallback" for missing key
# ===================

subtest 'get with default fallback returns fallback for missing key' => sub {
    my $session = PAGI::Session->from_data({});
    my $result = $session->get('missing', 'fallback');
    is $result, 'fallback', 'returns string default for missing key';
};

# ===================
# get with default still returns real value when key exists
# ===================

subtest 'get with default returns real value when key exists' => sub {
    my $session = PAGI::Session->from_data({});
    $session->set('color', 'blue');
    my $result = $session->get('color', 'red');
    is $result, 'blue', 'returns actual value, not the default';
};

# ===================
# id accessor
# ===================

subtest 'id accessor' => sub {
    my $session = PAGI::Session->from_data({ _id => 'abc123' });
    is $session->id, 'abc123', 'id returns _id from data';
};

# ===================
# regenerate sets _regenerated flag
# ===================

subtest 'regenerate sets _regenerated flag' => sub {
    my $data = {};
    my $session = PAGI::Session->from_data($data);
    $session->regenerate;
    is $data->{_regenerated}, 1, 'regenerate sets _regenerated = 1 in data';
};

# ===================
# destroy sets _destroyed flag
# ===================

subtest 'destroy sets _destroyed flag' => sub {
    my $data = {};
    my $session = PAGI::Session->from_data($data);
    $session->destroy;
    is $data->{_destroyed}, 1, 'destroy sets _destroyed = 1 in data';
};

# ===================
# exists checks key presence
# ===================

subtest 'exists checks key presence' => sub {
    my $session = PAGI::Session->from_data({});
    ok !$session->exists('nope'), 'exists returns false for missing key';

    $session->set('present', 'yes');
    ok $session->exists('present'), 'exists returns true for present key';
};

# ===================
# delete removes key
# ===================

subtest 'delete removes key' => sub {
    my $session = PAGI::Session->from_data({});
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
    my $session = PAGI::Session->from_data($data);
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

    my $session = PAGI::Session->from_data($scope->{'pagi.session'});
    is $session->id, 'scope-sess-1', 'id from scope session data';
    is $session->get('username'), 'bob', 'get username from scope session';
    is $session->get('role'), 'user', 'get role from scope session';

    my @keys = sort $session->keys;
    is \@keys, [qw(role username)], 'keys from scope session filters internals';
};

# ===================
# Bulk set
# ===================

subtest 'set multiple keys at once' => sub {
    my $data = { _id => 'bulk' };
    my $session = PAGI::Session->from_data($data);
    $session->set(user_id => 42, role => 'admin', email => 'john@test.com');
    is($data->{user_id}, 42, 'user_id set');
    is($data->{role}, 'admin', 'role set');
    is($data->{email}, 'john@test.com', 'email set');
};

subtest 'set dies on odd args greater than one' => sub {
    my $session = PAGI::Session->from_data({ _id => 'x' });
    ok(dies { $session->set('a', 'b', 'c') }, 'dies on 3 args');
};

# ===================
# Bulk delete
# ===================

subtest 'delete multiple keys at once' => sub {
    my $data = { _id => 'del', a => 1, b => 2, c => 3, d => 4 };
    my $session = PAGI::Session->from_data($data);
    $session->delete('a', 'c');
    ok(!exists $data->{a}, 'a deleted');
    is($data->{b}, 2, 'b preserved');
    ok(!exists $data->{c}, 'c deleted');
    is($data->{d}, 4, 'd preserved');
};

# ===================
# Slice
# ===================

subtest 'slice returns hash of existing keys' => sub {
    my $data = { _id => 'sl', user_id => 42, role => 'admin', email => 'j@t.com' };
    my $session = PAGI::Session->from_data($data);
    my %result = $session->slice('user_id', 'role');
    is(\%result, { user_id => 42, role => 'admin' }, 'got requested keys');
};

subtest 'slice skips missing keys silently' => sub {
    my $data = { _id => 'sl', user_id => 42 };
    my $session = PAGI::Session->from_data($data);
    my %result = $session->slice('user_id', 'role', 'missing');
    is(\%result, { user_id => 42 }, 'only existing keys returned');
};

subtest 'slice returns empty hash when no keys match' => sub {
    my $data = { _id => 'sl' };
    my $session = PAGI::Session->from_data($data);
    my %result = $session->slice('nope', 'nada');
    is(\%result, {}, 'empty hash');
};

# ===================
# Clear
# ===================

subtest 'clear removes user keys, preserves internal' => sub {
    my $data = { _id => 'cl', _created => 100, _last_access => 200,
                 user_id => 42, role => 'admin', cart => [1,2,3] };
    my $session = PAGI::Session->from_data($data);
    $session->clear;

    is($data->{_id}, 'cl', '_id preserved');
    is($data->{_created}, 100, '_created preserved');
    is($data->{_last_access}, 200, '_last_access preserved');
    ok(!exists $data->{user_id}, 'user_id cleared');
    ok(!exists $data->{role}, 'role cleared');
    ok(!exists $data->{cart}, 'cart cleared');
};

subtest 'clear on empty session is harmless' => sub {
    my $data = { _id => 'empty' };
    my $session = PAGI::Session->from_data($data);
    $session->clear;  # should not die
    is($data->{_id}, 'empty', '_id still there');
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
    ok(dies { PAGI::Session->new({}) }, 'dies on plain hashref without pagi.session');
    like(dies { PAGI::Session->new("bad") }, qr/requires/, 'error message');
};

# ===================
# from_data constructor
# ===================

subtest 'from_data wraps raw hashref' => sub {
    my $data = { _id => 'test123', user_id => 42 };
    my $session = PAGI::Session->from_data($data);
    is($session->id, 'test123', 'id from raw data');
    is($session->get('user_id'), 42, 'get from raw data');
};

subtest 'from_data mutations visible in original hashref' => sub {
    my $data = { _id => 'mut' };
    my $session = PAGI::Session->from_data($data);
    $session->set('added', 'yes');
    is($data->{added}, 'yes', 'mutation visible in original hashref');
};

# ===================
# new($scope) resolves scope
# ===================

subtest 'new resolves scope hashref with pagi.session' => sub {
    my $scope = {
        type => 'http',
        'pagi.session' => { _id => 'scope1', role => 'admin' },
    };
    my $session = PAGI::Session->new($scope);
    is($session->id, 'scope1', 'id from scope');
    is($session->get('role'), 'admin', 'data from scope');
};

subtest 'new resolves object with ->scope method' => sub {
    my $fake_obj = bless {
        _scope => {
            type => 'http',
            'pagi.session' => { _id => 'obj1', name => 'alice' },
        },
    }, 'FakeRequest';
    my $session = PAGI::Session->new($fake_obj);
    is($session->id, 'obj1', 'id from object scope');
    is($session->get('name'), 'alice', 'data from object scope');
};

subtest 'new ignores extra positional args' => sub {
    my $scope = {
        type => 'http',
        'pagi.session' => { _id => 'extra', count => 5 },
    };
    my $receive = sub {};
    my $send = sub {};
    my $session = PAGI::Session->new($scope, $receive, $send);
    is($session->id, 'extra', 'extra args ignored');
    is($session->get('count'), 5, 'data accessible');
};

subtest 'new dies on plain hashref without pagi.session' => sub {
    my $plain = { user_id => 42 };
    like(
        dies { PAGI::Session->new($plain) },
        qr/pagi\.session/i,
        'dies when scope has no pagi.session key'
    );
};

subtest 'new dies on invalid argument' => sub {
    like(dies { PAGI::Session->new("string") }, qr/requires/, 'dies on string');
    like(dies { PAGI::Session->new(undef) }, qr/requires/, 'dies on undef');
    like(dies { PAGI::Session->new() }, qr/requires/, 'dies on no args');
};

# ===================
# data method
# ===================

subtest 'data returns raw backing hashref' => sub {
    my $data = { _id => 'raw', user_id => 42, role => 'admin' };
    my $session = PAGI::Session->from_data($data);
    my $raw = $session->data;
    is($raw, $data, 'data returns same reference');
    is($raw->{user_id}, 42, 'can read through raw hashref');
};

subtest 'data mutations visible through get/set' => sub {
    my $session = PAGI::Session->from_data({ _id => 'dm' });
    $session->data->{color} = 'blue';
    is($session->get('color'), 'blue', 'direct mutation visible via get');

    $session->set('size', 'large');
    is($session->data->{size}, 'large', 'set visible via data');
};

# ===================
# set returns $self (chaining)
# ===================

subtest 'set returns self for chaining' => sub {
    my $session = PAGI::Session->from_data({ _id => 'ch' });
    my $result = $session->set('a', 1);
    ok($result == $session, 'set returns $self');

    # Chaining
    $session->set('x', 1)->set('y', 2)->set('z', 3);
    is($session->get('x'), 1, 'chained x');
    is($session->get('y'), 2, 'chained y');
    is($session->get('z'), 3, 'chained z');
};

# ===================
# delete returns $self (chaining)
# ===================

subtest 'delete returns self for chaining' => sub {
    my $session = PAGI::Session->from_data({ _id => 'dc', a => 1, b => 2, c => 3 });
    my $result = $session->delete('a');
    ok($result == $session, 'delete returns $self');

    # Chaining
    $session->delete('b')->delete('c');
    ok(!$session->exists('a'), 'a deleted');
    ok(!$session->exists('b'), 'b deleted');
    ok(!$session->exists('c'), 'c deleted');
};

# ===================
# get error messages aligned with Stash
# ===================

subtest 'get error lists available keys when few' => sub {
    my $session = PAGI::Session->from_data({ _id => 's', role => 'admin', theme => 'dark' });
    my $err = dies { $session->get('missing') };
    like($err, qr/Session key 'missing' does not exist/, 'error message format');
    like($err, qr/Available keys:/, 'lists available keys');
    like($err, qr/role/, 'mentions role');
    like($err, qr/theme/, 'mentions theme');
};

subtest 'get error reports count when many keys' => sub {
    my %data = (_id => 'big');
    $data{"key_$_"} = $_ for 1..15;
    my $session = PAGI::Session->from_data(\%data);
    my $err = dies { $session->get('nope') };
    like($err, qr/Session key 'nope' does not exist/, 'error message format');
    like($err, qr/session has 15 user keys/, 'reports count');
};

# ===================
# set validation: zero args no-op, single arg dies
# ===================

subtest 'set with zero args is no-op returning self' => sub {
    my $session = PAGI::Session->from_data({ _id => 'noop' });
    my $result = $session->set();
    ok($result == $session, 'zero-arg set returns $self');
};

subtest 'set with single arg dies' => sub {
    my $session = PAGI::Session->from_data({ _id => 'x' });
    ok(dies { $session->set('lonely') }, 'dies on single arg');
};

subtest 'set with three args dies' => sub {
    my $session = PAGI::Session->from_data({ _id => 'x' });
    ok(dies { $session->set('a', 'b', 'c') }, 'dies on odd args');
};

# Fake request class for duck-typing test
package FakeRequest;
sub scope { shift->{_scope} }

package main;

done_testing;
