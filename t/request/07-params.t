#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use lib 'lib';
use PAGI::Request;

subtest 'params from scope' => sub {
    my $scope = {
        type    => 'http',
        method  => 'GET',
        path    => '/users/42/posts/100',
        headers => [],
        # Router sets path_params directly in scope (router-agnostic)
        path_params => { user_id => '42', post_id => '100' },
        'pagi.router' => {
            route  => '/users/:user_id/posts/:post_id',
        },
    };

    my $req = PAGI::Request->new($scope);

    is($req->path_params, { user_id => '42', post_id => '100' }, 'params returns hashref');
    is($req->path_param('user_id'), '42', 'param() gets single value');
    is($req->path_param('post_id'), '100', 'param() another value');

    # path_param is strict by default - dies on missing key
    like(
        dies { $req->path_param('missing') },
        qr/path_param 'missing' not found/,
        'missing param dies (strict by default)'
    );
    is($req->path_param('missing', strict => 0), undef, 'strict => 0 returns undef');
};

subtest 'params set via scope' => sub {
    # Simulating how router sets path_params in scope before handler is called
    my $scope = {
        type => 'http',
        method => 'GET',
        headers => [],
        path_params => { id => '123', slug => 'hello-world' },
    };
    my $req = PAGI::Request->new($scope);

    is($req->path_param('id'), '123', 'param from scope');
    is($req->path_param('slug'), 'hello-world', 'another param');
};

subtest 'no params' => sub {
    my $scope = { type => 'http', method => 'GET', headers => [] };
    my $req = PAGI::Request->new($scope);

    is($req->path_params, {}, 'empty params by default');

    # path_param dies when no path params set (strict by default)
    like(
        dies { $req->path_param('anything') },
        qr/path_param 'anything' not found.*No path params set/,
        'path_param dies when no params set'
    );
    is($req->path_param('anything', strict => 0), undef, 'strict => 0 returns undef');
};

subtest 'path_param does not include query params' => sub {
    my $scope = {
        type => 'http',
        method => 'GET',
        headers => [],
        query_string => 'foo=bar&baz=qux',
        path_params => { id => '42' },
    };
    my $req = PAGI::Request->new($scope);

    # path_param only returns path params, not query params
    is($req->path_param('id'), '42', 'path param exists');

    # path_param dies for missing keys (doesn't fall back to query params)
    like(
        dies { $req->path_param('foo') },
        qr/path_param 'foo' not found/,
        'query param not returned by path_param (dies)'
    );
    like(
        dies { $req->path_param('baz') },
        qr/path_param 'baz' not found/,
        'path_param does not fall back to query params'
    );

    # Query params should be accessed via $req->query('foo')
    is($req->query('foo'), 'bar', 'query() returns query param');
    is($req->query('baz'), 'qux', 'query() returns another query param');
};

subtest 'path_param_strict mode (class config)' => sub {
    # This tests the CLASS-LEVEL path_param_strict config, which controls
    # whether path_params/path_param die when $scope->{path_params} is not set
    # (i.e., no router configured). This is separate from the PER-CALL strict
    # option which controls whether path_param dies on missing keys.

    # Save original config
    my $orig_strict = PAGI::Request->config->{path_param_strict};

    # Test non-strict mode (default) - returns empty without dying
    PAGI::Request->configure(path_param_strict => 0);
    my $scope_no_params = { type => 'http', method => 'GET', headers => [] };
    my $req = PAGI::Request->new($scope_no_params);

    is($req->path_params, {}, 'non-strict: path_params returns empty hashref');
    # Need strict => 0 to avoid the per-call key-existence check
    is($req->path_param('id', strict => 0), undef, 'non-strict: path_param returns undef');

    # Test strict mode - dies when path_params not in scope
    PAGI::Request->configure(path_param_strict => 1);
    $req = PAGI::Request->new($scope_no_params);

    like(
        dies { $req->path_params },
        qr/path_params not set in scope/,
        'strict: path_params dies when not set'
    );

    like(
        dies { $req->path_param('id') },
        qr/path_params not set in scope/,
        'strict: path_param dies when not set (class-level strict)'
    );

    # Strict mode should NOT die when path_params IS set
    my $scope_with_params = {
        type => 'http',
        method => 'GET',
        headers => [],
        path_params => { id => '42' },
    };
    $req = PAGI::Request->new($scope_with_params);

    is($req->path_params, { id => '42' }, 'strict: path_params works when set');
    is($req->path_param('id'), '42', 'strict: path_param works when set');

    # Restore original config
    PAGI::Request->configure(path_param_strict => $orig_strict);
};

done_testing;
