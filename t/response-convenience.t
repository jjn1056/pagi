use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Encode qw(encode);

use PAGI::Response;

my @sent;
my $send = sub {
    my ($msg) = @_;
    push @sent, $msg;
    return Future->done;
};

my $scope = { type => 'http' };

subtest 'stash accessor' => sub {
    my $scope_with_stash = {
        type => 'http',
    };
    my $res = PAGI::Response->new($scope_with_stash, $send);

    # Default stash is empty hashref
    is($res->stash, {}, 'stash returns empty hashref by default');

    # Can set values
    $res->stash->{user} = { id => 1, name => 'test' };
    is($res->stash->{user}{id}, 1, 'stash values persist');

    # Stash lives in scope
    is($scope_with_stash->{'pagi.stash'}{user}{id}, 1, 'stash lives in scope');
};

subtest 'stash shared with Request' => sub {
    # This tests the key design: Request and Response share the same stash
    my $shared_scope = {
        type => 'http',
        method => 'GET',
        path => '/test',
        headers => [],
    };

    # Simulate middleware setting stash via Request
    require PAGI::Request;
    my $req = PAGI::Request->new($shared_scope);
    $req->stash->{user} = { id => 42, role => 'admin' };

    # Response should see the same stash
    my $res = PAGI::Response->new($shared_scope, $send);
    is($res->stash->{user}{id}, 42, 'Response sees stash set by Request');
    is($res->stash->{user}{role}, 'admin', 'full structure accessible');

    # Modifications via Response are visible to Request
    $res->stash->{request_id} = 'abc123';
    is($req->stash->{request_id}, 'abc123', 'Request sees stash set by Response');
};

subtest 'stash survives scope shallow copy' => sub {
    # This tests why the technical concern about Request being ephemeral is moot
    my $original_scope = {
        type => 'http',
    };

    # Set stash on original scope
    my $res1 = PAGI::Response->new($original_scope, $send);
    $res1->stash->{user} = 'alice';

    # Middleware creates shallow copy (what PAGI middleware does)
    my $new_scope = {
        %$original_scope,
        path => '/modified',
    };

    # New Response on copied scope should see the same stash
    my $res2 = PAGI::Response->new($new_scope, $send);
    is($res2->stash->{user}, 'alice', 'stash survives shallow copy');

    # They share the same stash reference
    $res2->stash->{role} = 'admin';
    is($res1->stash->{role}, 'admin', 'stash modifications visible across copies');
};

done_testing;
