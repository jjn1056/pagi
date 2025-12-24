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

done_testing;
