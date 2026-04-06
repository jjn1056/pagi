#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use PAGI::Stash;

# ===================
# from_data constructor
# ===================

subtest 'from_data wraps raw hashref' => sub {
    my $data = { user => 'alice', role => 'admin' };
    my $stash = PAGI::Stash->from_data($data);
    is($stash->get('user'), 'alice', 'get from raw data');
    is($stash->get('role'), 'admin', 'get another key');
};

subtest 'from_data mutations visible in original' => sub {
    my $data = {};
    my $stash = PAGI::Stash->from_data($data);
    $stash->set(color => 'blue');
    is($data->{color}, 'blue', 'mutation visible');
};

subtest 'from_data dies without hashref' => sub {
    ok(dies { PAGI::Stash->from_data("bad") }, 'dies on string');
    ok(dies { PAGI::Stash->from_data(undef) }, 'dies on undef');
};

# ===================
# new($scope) — scope-based constructor
# ===================

subtest 'new from scope hashref' => sub {
    my $scope = { type => 'http' };
    my $stash = PAGI::Stash->new($scope);
    $stash->set(user => 'bob');
    is($scope->{'pagi.stash'}{user}, 'bob', 'stash created lazily in scope');
};

subtest 'new from scope with existing pagi.stash' => sub {
    my $scope = { type => 'http', 'pagi.stash' => { existing => 1 } };
    my $stash = PAGI::Stash->new($scope);
    is($stash->get('existing'), 1, 'uses existing stash data');
};

subtest 'new from object with ->scope' => sub {
    my $scope = { type => 'http' };
    my $fake_req = bless { _scope => $scope }, 'FakeReqForStash';
    my $stash = PAGI::Stash->new($fake_req);
    $stash->set(x => 42);
    is($scope->{'pagi.stash'}{x}, 42, 'stash lives in object scope');
};

subtest 'new ignores extra positional args' => sub {
    my $scope = { type => 'http' };
    my $receive = sub {};
    my $send = sub {};
    my $stash = PAGI::Stash->new($scope, $receive, $send);
    $stash->set(ok => 1);
    is($stash->get('ok'), 1, 'works with extra args');
};

subtest 'new dies on invalid argument' => sub {
    like(dies { PAGI::Stash->new("string") }, qr/requires/, 'dies on string');
    like(dies { PAGI::Stash->new(undef) }, qr/requires/, 'dies on undef');
    like(dies { PAGI::Stash->new() }, qr/requires/, 'dies on no args');
};

# ===================
# get — strict and permissive
# ===================

subtest 'get strict dies on missing key' => sub {
    my $stash = PAGI::Stash->from_data({});
    ok(dies { $stash->get('nope') }, 'dies on missing key');
};

subtest 'get strict error lists keys when few' => sub {
    my $stash = PAGI::Stash->from_data({ alpha => 1, beta => 2, gamma => 3 });
    my $err = dies { $stash->get('missing') };
    like($err, qr/Stash key 'missing' does not exist/, 'error format');
    like($err, qr/Available keys:/, 'lists keys');
    like($err, qr/alpha/, 'mentions alpha');
    like($err, qr/beta/, 'mentions beta');
    like($err, qr/gamma/, 'mentions gamma');
};

subtest 'get strict error reports count when many keys' => sub {
    my %data;
    $data{"k$_"} = $_ for 1..15;
    my $stash = PAGI::Stash->from_data(\%data);
    my $err = dies { $stash->get('nope') };
    like($err, qr/Stash key 'nope' does not exist/, 'error format');
    like($err, qr/stash has 15 keys/, 'reports count');
};

subtest 'get with default returns default for missing' => sub {
    my $stash = PAGI::Stash->from_data({});
    is($stash->get('x', 'fallback'), 'fallback', 'string default');
    is($stash->get('x', 0), 0, 'zero default');
    is($stash->get('x', undef), undef, 'undef default');
};

subtest 'get with default returns real value when exists' => sub {
    my $stash = PAGI::Stash->from_data({ color => 'blue' });
    is($stash->get('color', 'red'), 'blue', 'returns actual value');
};

subtest 'get dies on zero args' => sub {
    my $stash = PAGI::Stash->from_data({});
    ok(dies { $stash->get() }, 'dies on zero args');
};

subtest 'get dies on more than two args' => sub {
    my $stash = PAGI::Stash->from_data({});
    ok(dies { $stash->get('a', 'b', 'c') }, 'dies on three args');
};

# ===================
# set
# ===================

subtest 'set single pair' => sub {
    my $stash = PAGI::Stash->from_data({});
    $stash->set(user => 'alice');
    is($stash->get('user'), 'alice', 'single pair set');
};

subtest 'set multiple pairs' => sub {
    my $stash = PAGI::Stash->from_data({});
    $stash->set(a => 1, b => 2, c => 3);
    is($stash->get('a'), 1, 'a set');
    is($stash->get('b'), 2, 'b set');
    is($stash->get('c'), 3, 'c set');
};

subtest 'set returns self for chaining' => sub {
    my $stash = PAGI::Stash->from_data({});
    my $result = $stash->set(x => 1);
    ok($result == $stash, 'returns $self');

    $stash->set(a => 1)->set(b => 2);
    is($stash->get('a'), 1, 'chained a');
    is($stash->get('b'), 2, 'chained b');
};

subtest 'set no-ops on zero args' => sub {
    my $stash = PAGI::Stash->from_data({});
    my $result = $stash->set();
    ok($result == $stash, 'zero-arg returns $self');
};

subtest 'set dies on odd args' => sub {
    my $stash = PAGI::Stash->from_data({});
    ok(dies { $stash->set('lonely') }, 'dies on 1 arg');
    ok(dies { $stash->set('a', 'b', 'c') }, 'dies on 3 args');
};

# ===================
# exists
# ===================

subtest 'exists returns boolean' => sub {
    my $stash = PAGI::Stash->from_data({ present => 1 });
    is($stash->exists('present'), 1, 'true for present key');
    is($stash->exists('absent'), 0, 'false for absent key');
};

# ===================
# delete
# ===================

subtest 'delete removes keys' => sub {
    my $stash = PAGI::Stash->from_data({ a => 1, b => 2, c => 3 });
    $stash->delete('a');
    ok(!$stash->exists('a'), 'a deleted');
    ok($stash->exists('b'), 'b preserved');
};

subtest 'delete multiple keys' => sub {
    my $stash = PAGI::Stash->from_data({ a => 1, b => 2, c => 3 });
    $stash->delete('a', 'c');
    ok(!$stash->exists('a'), 'a deleted');
    ok($stash->exists('b'), 'b preserved');
    ok(!$stash->exists('c'), 'c deleted');
};

subtest 'delete returns self for chaining' => sub {
    my $stash = PAGI::Stash->from_data({ a => 1, b => 2 });
    my $result = $stash->delete('a');
    ok($result == $stash, 'returns $self');
    $stash->delete('b');
    ok(!$stash->exists('a'), 'a gone');
    ok(!$stash->exists('b'), 'b gone');
};

# ===================
# keys
# ===================

subtest 'keys returns all keys' => sub {
    my $stash = PAGI::Stash->from_data({ x => 1, y => 2, _z => 3 });
    my @keys = sort $stash->keys;
    is(\@keys, [qw(_z x y)], 'returns all keys including underscore-prefixed');
};

subtest 'keys on empty stash' => sub {
    my $stash = PAGI::Stash->from_data({});
    my @keys = $stash->keys;
    is(\@keys, [], 'empty list');
};

# ===================
# slice
# ===================

subtest 'slice returns matching keys' => sub {
    my $stash = PAGI::Stash->from_data({ a => 1, b => 2, c => 3 });
    my %result = $stash->slice('a', 'c');
    is(\%result, { a => 1, c => 3 }, 'got requested keys');
};

subtest 'slice skips missing keys' => sub {
    my $stash = PAGI::Stash->from_data({ a => 1 });
    my %result = $stash->slice('a', 'b', 'c');
    is(\%result, { a => 1 }, 'only existing key returned');
};

subtest 'slice returns empty hash when nothing matches' => sub {
    my $stash = PAGI::Stash->from_data({});
    my %result = $stash->slice('x', 'y');
    is(\%result, {}, 'empty hash');
};

# ===================
# data
# ===================

subtest 'data returns raw backing hashref' => sub {
    my $data = { user => 'alice' };
    my $stash = PAGI::Stash->from_data($data);
    is($stash->data, $data, 'same reference');
};

subtest 'data mutations visible through methods' => sub {
    my $stash = PAGI::Stash->from_data({});
    $stash->data->{x} = 42;
    is($stash->get('x'), 42, 'direct mutation visible via get');

    $stash->set(y => 99);
    is($stash->data->{y}, 99, 'set visible via data');
};

subtest 'data creates pagi.stash lazily in scope' => sub {
    my $scope = { type => 'http' };
    my $stash = PAGI::Stash->new($scope);
    my $raw = $stash->data;
    is(ref($raw), 'HASH', 'data returns hashref');
    ok(exists $scope->{'pagi.stash'}, 'pagi.stash created in scope');
    is($scope->{'pagi.stash'}, $raw, 'same reference');
};

# ===================
# Scope sharing
# ===================

subtest 'multiple Stash instances share same scope data' => sub {
    my $scope = { type => 'http' };
    my $s1 = PAGI::Stash->new($scope);
    my $s2 = PAGI::Stash->new($scope);

    $s1->set(shared => 'yes');
    is($s2->get('shared'), 'yes', 'second instance sees first instance data');
};

subtest 'different scopes are independent' => sub {
    my $scope1 = { type => 'http' };
    my $scope2 = { type => 'http' };
    my $s1 = PAGI::Stash->new($scope1);
    my $s2 = PAGI::Stash->new($scope2);

    $s1->set(val => 'first');
    $s2->set(val => 'second');

    is($s1->get('val'), 'first', 'scope1 independent');
    is($s2->get('val'), 'second', 'scope2 independent');
};

# Helper class for duck-typing tests
package FakeReqForStash;
sub scope { shift->{_scope} }

package main;

done_testing;
