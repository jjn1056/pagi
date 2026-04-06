use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Encode qw(encode);

use PAGI::Response;
use PAGI::Stash;

my @sent;
my $send = sub {
    my ($msg) = @_;
    push @sent, $msg;
    return Future->done;
};

my $scope = { type => 'http' };

subtest 'scope accessor returns scope hashref' => sub {
    my $test_scope = { type => 'http' };
    my $res = PAGI::Response->new($test_scope, $send);
    ok($res->scope == $test_scope, 'scope returns same hashref');
};

subtest 'stash accessor' => sub {
    my $scope_with_stash = {
        type => 'http',
    };
    my $res = PAGI::Response->new($scope_with_stash, $send);
    my $stash = PAGI::Stash->new($res);

    # Default stash is empty hashref
    is($stash->data, {}, 'stash returns empty hashref by default');

    # Can set values
    $stash->set(user => { id => 1, name => 'test' });
    is($stash->get('user')->{id}, 1, 'stash values persist');

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
    PAGI::Stash->new($req)->set(user => { id => 42, role => 'admin' });

    # Response should see the same stash (via shared scope)
    my $res = PAGI::Response->new($shared_scope, $send);
    my $stash = PAGI::Stash->new($res);
    is($stash->get('user')->{id}, 42, 'Response sees stash set by Request');
    is($stash->get('user')->{role}, 'admin', 'full structure accessible');

    # Modifications via Response stash are visible to Request stash
    $stash->set(request_id => 'abc123');
    is(PAGI::Stash->new($req)->get('request_id'), 'abc123', 'Request sees stash set by Response');
};

subtest 'stash survives scope shallow copy' => sub {
    # This tests why the technical concern about Request being ephemeral is moot
    my $original_scope = {
        type => 'http',
    };

    # Set stash on original scope
    my $res1 = PAGI::Response->new($original_scope, $send);
    PAGI::Stash->new($res1)->set(user => 'alice');

    # Middleware creates shallow copy (what PAGI middleware does)
    my $new_scope = {
        %$original_scope,
        path => '/modified',
    };

    # New Response on copied scope should see the same stash
    my $res2 = PAGI::Response->new($new_scope, $send);
    my $stash2 = PAGI::Stash->new($res2);
    is($stash2->get('user'), 'alice', 'stash survives shallow copy');

    # They share the same stash reference
    $stash2->set(role => 'admin');
    is(PAGI::Stash->new($res1)->get('role'), 'admin', 'stash modifications visible across copies');
};

done_testing;
