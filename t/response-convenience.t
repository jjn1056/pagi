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

subtest 'param and params read from scope' => sub {
    my $scope_with_params = {
        type => 'http',
        path_params => { id => '42', action => 'edit' },
    };
    my $res = PAGI::Response->new($send, $scope_with_params);

    is($res->path_param('id'), '42', 'param returns route param from scope');
    is($res->path_param('action'), 'edit', 'param returns another param');
    is($res->path_param('missing'), undef, 'param returns undef for missing');
    is($res->path_params, { id => '42', action => 'edit' }, 'params returns all');
};

subtest 'param returns undef when no route params' => sub {
    my $res = PAGI::Response->new($send, $scope);
    is($res->path_param('anything'), undef, 'param returns undef when no params');
    is($res->path_params, {}, 'params returns empty hash');
};

subtest 'param returns undef when no scope provided' => sub {
    my $res = PAGI::Response->new($send);
    is($res->path_param('anything'), undef, 'param returns undef when no scope');
    is($res->path_params, {}, 'params returns empty hash when no scope');
};

subtest 'backward compatibility - constructor works without scope' => sub {
    my $res = PAGI::Response->new($send);
    isa_ok $res, 'PAGI::Response';

    # Should still be able to use all other methods
    @sent = ();
    $res->status(200)->header('X-Test' => 'value');
    $res->text("Hello")->get;

    is scalar(@sent), 2, 'response sent successfully';
    is $sent[0]->{status}, 200, 'status set';
    is $sent[1]->{body}, encode('UTF-8', 'Hello'), 'body sent';
};

subtest 'params with complex route params' => sub {
    my $scope_complex = {
        type => 'http',
        path_params => {
            user_id => '123',
            post_id => '456',
            format  => 'json',
        },
    };
    my $res = PAGI::Response->new($send, $scope_complex);

    is($res->path_param('user_id'), '123', 'user_id param');
    is($res->path_param('post_id'), '456', 'post_id param');
    is($res->path_param('format'), 'json', 'format param');

    my $all_params = $res->path_params;
    is($all_params->{user_id}, '123', 'all params has user_id');
    is($all_params->{post_id}, '456', 'all params has post_id');
    is($all_params->{format}, 'json', 'all params has format');
};

subtest 'params when path_params key missing' => sub {
    my $scope_no_params = {
        type => 'http',
    };
    my $res = PAGI::Response->new($send, $scope_no_params);

    is($res->path_param('anything'), undef, 'param returns undef');
    is($res->path_params, {}, 'params returns empty hash');
};

subtest 'stash accessor' => sub {
    my $scope_with_stash = {
        type => 'http',
    };
    my $res = PAGI::Response->new($send, $scope_with_stash);

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
    my $res = PAGI::Response->new($send, $shared_scope);
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
    my $res1 = PAGI::Response->new($send, $original_scope);
    $res1->stash->{user} = 'alice';

    # Middleware creates shallow copy (what PAGI middleware does)
    my $new_scope = {
        %$original_scope,
        path => '/modified',
    };

    # New Response on copied scope should see the same stash
    my $res2 = PAGI::Response->new($send, $new_scope);
    is($res2->stash->{user}, 'alice', 'stash survives shallow copy');

    # They share the same stash reference
    $res2->stash->{role} = 'admin';
    is($res1->stash->{role}, 'admin', 'stash modifications visible across copies');
};

subtest 'stash returns empty hash when no scope' => sub {
    my $res = PAGI::Response->new($send);
    is($res->stash, {}, 'stash returns empty hash when no scope');
};

done_testing;
