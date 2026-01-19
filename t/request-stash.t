use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;

use PAGI::Request;

my $receive = sub { Future->done({ type => 'http.request', body => '' }) };

subtest 'stash accessor' => sub {
    my $scope = {
        type         => 'http',
        method       => 'GET',
        path         => '/test',
        query_string => '',
        headers      => [],
    };

    my $req = PAGI::Request->new($scope, $receive);

    # Default stash is empty hashref
    is($req->stash, {}, 'stash returns empty hashref by default');

    # Can set values
    $req->stash->{user} = { id => 1, name => 'test' };
    is($req->stash->{user}{id}, 1, 'stash values persist');
};

subtest 'stash lives in scope' => sub {
    my $scope = {
        type         => 'http',
        method       => 'GET',
        path         => '/test',
        query_string => '',
        headers      => [],
    };

    my $req = PAGI::Request->new($scope, $receive);

    $req->stash->{db} = 'connection';
    $req->stash->{config} = { debug => 1 };

    is($req->stash->{db}, 'connection', 'stash sets values');
    is($req->stash->{config}{debug}, 1, 'nested values work');
    is($scope->{'pagi.stash'}{db}, 'connection', 'stash lives in scope');
};

subtest 'stash shared via scope enables middleware data sharing' => sub {
    my $scope = {
        type         => 'http',
        method       => 'GET',
        path         => '/test',
        query_string => '',
        headers      => [],
    };

    # Simulate middleware setting a value
    my $req1 = PAGI::Request->new($scope, $receive);
    $req1->stash->{user} = { id => 42, role => 'admin' };

    # Simulate handler reading middleware-set value (same scope)
    my $req2 = PAGI::Request->new($scope, $receive);
    my $user = $req2->stash->{user};

    is($user->{id}, 42, 'handler sees middleware-set value');
    is($user->{role}, 'admin', 'full structure accessible');
};

subtest 'param returns route parameters from scope' => sub {
    my $scope_with_route_params = {
        type         => 'http',
        method       => 'GET',
        path         => '/test',
        query_string => '',
        headers      => [],
        path_params => { id => '123', action => 'edit' },
    };

    my $req = PAGI::Request->new($scope_with_route_params, $receive);

    is($req->path_param('id'), '123', 'param returns route param from scope');
    is($req->path_param('action'), 'edit', 'param returns another param');

    # Strict by default - missing param dies with helpful message
    like(
        dies { $req->path_param('missing') },
        qr/path_param 'missing' not found.*Available:.*action.*id/s,
        'path_param dies on missing key (strict by default)'
    );

    # Can opt out with strict => 0
    is($req->path_param('missing', strict => 0), undef, 'strict => 0 returns undef for missing');
};

subtest 'path_param only returns path params, not query params' => sub {
    my $scope_with_query = {
        type         => 'http',
        method       => 'GET',
        path         => '/test',
        query_string => 'foo=bar&baz=qux',
        headers      => [],
    };

    my $req = PAGI::Request->new($scope_with_query, $receive);

    # path_param dies when no path params set (strict by default)
    like(
        dies { $req->path_param('foo') },
        qr/path_param 'foo' not found.*No path params set/,
        'path_param dies when no path params set'
    );

    # With strict => 0, returns undef
    is($req->path_param('foo', strict => 0), undef, 'strict => 0 returns undef when no path params');
    is($req->query_param('foo'), 'bar', 'query() returns query param');

    # With route params in scope, path_param returns them
    $scope_with_query->{path_params} = { foo => 'route_value' };
    is($req->path_param('foo'), 'route_value', 'path_param returns path param');

    # Missing path param dies even when other path params exist
    like(
        dies { $req->path_param('baz') },
        qr/path_param 'baz' not found.*Available:.*foo/,
        'path_param dies for missing key (does not fall back to query)'
    );
    is($req->path_param('baz', strict => 0), undef, 'strict => 0 returns undef for missing');
    is($req->query_param('baz'), 'qux', 'query() returns query param');
};

done_testing;
