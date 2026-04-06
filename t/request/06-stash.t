#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use lib 'lib';
use PAGI::Request;
use PAGI::Stash;

subtest 'scope accessor returns scope hashref' => sub {
    my $scope = { type => 'http', method => 'GET', headers => [] };
    my $req = PAGI::Request->new($scope);
    ok($req->scope == $scope, 'scope returns same hashref');
};

subtest 'stash basic usage' => sub {
    my $scope = { type => 'http', method => 'GET', headers => [] };
    my $req = PAGI::Request->new($scope);
    my $stash = PAGI::Stash->new($scope);

    # Starts empty
    is($stash->data, {}, 'stash starts empty');

    # Can set values
    $stash->set(user => { id => 42, name => 'John' }, authenticated => 1);

    # Can read values
    is($stash->get('user')->{id}, 42, 'read nested value');
    is($stash->get('authenticated'), 1, 'read simple value');
};

subtest 'stash persists on same request' => sub {
    my $scope = { type => 'http', method => 'GET', headers => [] };
    my $req = PAGI::Request->new($scope);
    my $stash = PAGI::Stash->new($scope);

    $stash->set(counter => 1);
    $stash->data->{counter}++;
    $stash->data->{counter}++;

    is($stash->get('counter'), 3, 'modifications persist');
};

subtest 'stash lives in scope' => sub {
    my $scope = { type => 'http', method => 'GET', headers => [] };
    my $req = PAGI::Request->new($scope);
    my $stash = PAGI::Stash->new($scope);

    $stash->set(user => 'alice');

    is($stash->get('user'), 'alice', 'stash persists');
    is($scope->{'pagi.stash'}{user}, 'alice', 'stash lives in scope');
};

subtest 'stash shared via scope' => sub {
    # Same scope = same stash (important for middleware flow)
    my $scope = { type => 'http', method => 'GET', headers => [] };
    my $stash1 = PAGI::Stash->new($scope);
    my $stash2 = PAGI::Stash->new($scope);

    $stash1->set(foo => 'bar');

    is($stash2->get('foo'), 'bar', 'same scope = same stash');
};

subtest 'stash isolated with different scopes' => sub {
    # Different scopes = different stashes
    my $scope1 = { type => 'http', method => 'GET', headers => [] };
    my $scope2 = { type => 'http', method => 'GET', headers => [] };
    my $stash1 = PAGI::Stash->new($scope1);
    my $stash2 = PAGI::Stash->new($scope2);

    $stash1->set(value => 'first');
    $stash2->set(value => 'second');

    is($stash1->get('value'), 'first', 'req1 has its own stash');
    is($stash2->get('value'), 'second', 'req2 has its own stash');
};

done_testing;
