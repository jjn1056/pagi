use strict;
use warnings;
use Test2::V0;

require PAGI::Request;

subtest 'state accessor reads from scope' => sub {
    my $scope = {
        type    => 'http',
        method  => 'GET',
        path    => '/',
        headers => [],
        state => { db => 'test-connection', config => { env => 'test' } },
    };

    my $req = PAGI::Request->new($scope, sub { });

    is(ref($req->state), 'HASH', 'state returns hashref');
    is($req->state->{db}, 'test-connection', 'state contains db');
    is($req->state->{config}{env}, 'test', 'state contains nested config');
};

subtest 'state returns empty hash if not set' => sub {
    my $scope = {
        type    => 'http',
        method  => 'GET',
        path    => '/',
        headers => [],
    };

    my $req = PAGI::Request->new($scope, sub { });

    is(ref($req->state), 'HASH', 'state returns hashref');
    is($req->state, {}, 'state is empty hash when not injected');
};

subtest 'state is separate from stash' => sub {
    my $scope = {
        type    => 'http',
        method  => 'GET',
        path    => '/',
        headers => [],
        state => { db => 'connection' },
    };

    my $req = PAGI::Request->new($scope, sub { });

    # Set something in stash
    $req->stash->{user} = 'alice';

    # Verify they are separate
    is($req->state->{db}, 'connection', 'state has app data');
    is($req->stash->{user}, 'alice', 'stash has request data');
    ok(!exists $req->state->{user}, 'state does not have stash data');
    ok(!exists $req->stash->{db}, 'stash does not have state data');
};

done_testing;
