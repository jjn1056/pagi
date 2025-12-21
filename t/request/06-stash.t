#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use lib 'lib';
use PAGI::Request;

subtest 'stash basic usage' => sub {
    my $scope = { type => 'http', method => 'GET', headers => [] };
    my $req = PAGI::Request->new($scope);

    # Starts empty
    is($req->stash, {}, 'stash starts empty');

    # Can set values
    $req->stash->{user} = { id => 42, name => 'John' };
    $req->stash->{authenticated} = 1;

    # Can read values
    is($req->stash->{user}{id}, 42, 'read nested value');
    is($req->stash->{authenticated}, 1, 'read simple value');
};

subtest 'stash persists on same request' => sub {
    my $scope = { type => 'http', method => 'GET', headers => [] };
    my $req = PAGI::Request->new($scope);

    $req->stash->{counter} = 1;
    $req->stash->{counter}++;
    $req->stash->{counter}++;

    is($req->stash->{counter}, 3, 'modifications persist');
};

subtest 'stash isolated between requests' => sub {
    my $scope = { type => 'http', method => 'GET', headers => [] };
    my $req1 = PAGI::Request->new($scope);
    my $req2 = PAGI::Request->new($scope);

    $req1->stash->{value} = 'first';
    $req2->stash->{value} = 'second';

    is($req1->stash->{value}, 'first', 'req1 has its own stash');
    is($req2->stash->{value}, 'second', 'req2 has its own stash');
};

done_testing;
