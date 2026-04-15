#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use lib 'lib';
use PAGI::Request;

subtest 'constructor and basic properties' => sub {
    my $scope = {
        type         => 'http',
        method       => 'GET',
        path         => '/users/42',
        raw_path     => '/users/42',
        query_string => 'foo=bar&baz=qux',
        scheme       => 'https',
        http_version => '1.1',
        headers      => [
            ['host', 'example.com'],
            ['content-type', 'application/json'],
            ['accept', 'text/html'],
            ['accept', 'application/json'],
        ],
        client => ['127.0.0.1', 54321],
    };

    my $req = PAGI::Request->new($scope);

    is($req->method, 'GET', 'method');
    is($req->path, '/users/42', 'path');
    is($req->raw_path, '/users/42', 'raw_path');
    is($req->query_string, 'foo=bar&baz=qux', 'query_string');
    is($req->scheme, 'https', 'scheme');
    is($req->host, 'example.com', 'host from headers');
    is($req->content_type, 'application/json', 'content_type');
    is($req->client, ['127.0.0.1', 54321], 'client');
};

subtest 'predicate methods' => sub {
    my $get_scope = { type => 'http', method => 'GET', headers => [] };
    my $post_scope = { type => 'http', method => 'POST', headers => [] };

    my $get_req = PAGI::Request->new($get_scope);
    my $post_req = PAGI::Request->new($post_scope);

    ok($get_req->is_get, 'is_get true for GET');
    ok(!$get_req->is_post, 'is_post false for GET');
    ok($post_req->is_post, 'is_post true for POST');
    ok(!$post_req->is_get, 'is_get false for POST');
};

subtest 'all method predicates' => sub {
    my @methods = qw(GET POST PUT PATCH DELETE HEAD OPTIONS);
    my @predicates = qw(is_get is_post is_put is_patch is_delete is_head is_options);

    for my $i (0 .. $#methods) {
        my $method = $methods[$i];
        my $scope = { type => 'http', method => $method, headers => [] };
        my $req = PAGI::Request->new($scope);

        for my $j (0 .. $#predicates) {
            my $predicate = $predicates[$j];
            if ($i == $j) {
                ok($req->$predicate, "$predicate true for $method");
            } else {
                ok(!$req->$predicate, "$predicate false for $method");
            }
        }
    }
};

subtest 'content_length method' => sub {
    my $scope = {
        type => 'http',
        method => 'POST',
        headers => [
            ['content-length', '1234'],
            ['content-type', 'application/json'],
        ],
    };

    my $req = PAGI::Request->new($scope);
    is($req->content_length, '1234', 'content_length returns correct value');

    # Test without content-length header
    my $scope_no_cl = {
        type => 'http',
        method => 'GET',
        headers => [],
    };
    my $req_no_cl = PAGI::Request->new($scope_no_cl);
    is($req_no_cl->content_length, undef, 'content_length returns undef when missing');
};

subtest 'http_version property' => sub {
    my $scope_11 = {
        type => 'http',
        method => 'GET',
        http_version => '1.1',
        headers => [],
    };
    my $req_11 = PAGI::Request->new($scope_11);
    is($req_11->http_version, '1.1', 'http_version returns 1.1');

    my $scope_10 = {
        type => 'http',
        method => 'GET',
        http_version => '1.0',
        headers => [],
    };
    my $req_10 = PAGI::Request->new($scope_10);
    is($req_10->http_version, '1.0', 'http_version returns 1.0');
};

subtest 'raw property returns full scope' => sub {
    my $scope = {
        type => 'http',
        method => 'POST',
        path => '/test',
        headers => [['host', 'example.com']],
        custom_field => 'custom_value',
    };

    my $req = PAGI::Request->new($scope);
    is($req->raw, $scope, 'raw returns the full scope hash');
    is($req->raw->{custom_field}, 'custom_value', 'raw includes custom fields');
};

subtest 'case-insensitive header lookup' => sub {
    my $scope = {
        type => 'http',
        method => 'GET',
        headers => [
            ['host', 'example.com'],
            ['Content-Type', 'application/json'],
            ['X-Custom-Header', 'custom-value'],
        ],
    };

    my $req = PAGI::Request->new($scope);

    # Test various case combinations
    is($req->header('host'), 'example.com', 'lowercase header name');
    is($req->header('Host'), 'example.com', 'capitalized header name');
    is($req->header('HOST'), 'example.com', 'uppercase header name');
    is($req->header('HoSt'), 'example.com', 'mixed case header name');

    is($req->header('content-type'), 'application/json', 'content-type lowercase');
    is($req->header('Content-Type'), 'application/json', 'content-type original case');
    is($req->header('CONTENT-TYPE'), 'application/json', 'content-type uppercase');

    is($req->header('x-custom-header'), 'custom-value', 'custom header lowercase');
    is($req->header('X-Custom-Header'), 'custom-value', 'custom header original case');
    is($req->header('X-CUSTOM-HEADER'), 'custom-value', 'custom header uppercase');
};

subtest 'multiple headers with same name returns last value' => sub {
    my $scope = {
        type => 'http',
        method => 'GET',
        headers => [
            ['accept', 'text/html'],
            ['accept', 'application/json'],
            ['accept', 'text/plain'],
            ['x-custom', 'first'],
            ['x-custom', 'second'],
            ['x-custom', 'third'],
        ],
    };

    my $req = PAGI::Request->new($scope);
    is($req->header('accept'), 'text/plain', 'returns last accept header value');
    is($req->header('x-custom'), 'third', 'returns last x-custom header value');
};

subtest 'content-type parameter stripping' => sub {
    my $scope = {
        type => 'http',
        method => 'POST',
        headers => [
            ['content-type', 'application/json; charset=utf-8'],
        ],
    };

    my $req = PAGI::Request->new($scope);
    is($req->content_type, 'application/json', 'content_type strips charset parameter');

    # Test with multiple parameters
    my $scope_multi = {
        type => 'http',
        method => 'POST',
        headers => [
            ['content-type', 'text/html; charset=utf-8; boundary=something'],
        ],
    };
    my $req_multi = PAGI::Request->new($scope_multi);
    is($req_multi->content_type, 'text/html', 'content_type strips all parameters');

    # Test without parameters
    my $scope_plain = {
        type => 'http',
        method => 'POST',
        headers => [
            ['content-type', 'application/xml'],
        ],
    };
    my $req_plain = PAGI::Request->new($scope_plain);
    is($req_plain->content_type, 'application/xml', 'content_type without parameters');
};

subtest 'optional receive parameter in constructor' => sub {
    my $scope = {
        type => 'http',
        method => 'GET',
        headers => [],
    };

    # Without $receive
    my $req_no_receive = PAGI::Request->new($scope);
    ok($req_no_receive, 'constructor works without $receive parameter');
    is($req_no_receive->{receive}, undef, 'receive is undef when not provided');

    # With $receive
    my $receive = sub { };
    my $req_with_receive = PAGI::Request->new($scope, $receive);
    ok($req_with_receive, 'constructor works with $receive parameter');
    is($req_with_receive->{receive}, $receive, 'receive is stored when provided');
};

subtest 'defaults and fallbacks' => sub {
    # Test raw_path with explicit value
    my $scope_with_raw = {
        type => 'http',
        method => 'GET',
        path => '/path',
        raw_path => '/raw/path',
        headers => [],
    };
    my $req_with_raw = PAGI::Request->new($scope_with_raw);
    is($req_with_raw->raw_path, '/raw/path', 'raw_path returns value when provided');

    # Test raw_path fallback to path
    my $scope_no_raw = {
        type => 'http',
        method => 'GET',
        path => '/fallback/path',
        headers => [],
    };
    my $req_no_raw = PAGI::Request->new($scope_no_raw);
    is($req_no_raw->raw_path, '/fallback/path', 'raw_path falls back to path when missing');

    # Test query_string defaults to empty string
    my $scope_no_qs = {
        type => 'http',
        method => 'GET',
        raw_path => '/test',
        headers => [],
    };
    my $req_no_qs = PAGI::Request->new($scope_no_qs);
    is($req_no_qs->query_string, '', 'query_string defaults to empty string');

    # Test scheme defaults to http
    my $scope_no_scheme = {
        type => 'http',
        method => 'GET',
        raw_path => '/test',
        headers => [],
    };
    my $req_no_scheme = PAGI::Request->new($scope_no_scheme);
    is($req_no_scheme->scheme, 'http', 'scheme defaults to http');

    # Test http_version defaults to 1.1
    my $scope_no_version = {
        type => 'http',
        method => 'GET',
        raw_path => '/test',
        headers => [],
    };
    my $req_no_version = PAGI::Request->new($scope_no_version);
    is($req_no_version->http_version, '1.1', 'http_version defaults to 1.1');

    # Test all defaults together
    my $minimal_scope = {
        type => 'http',
        method => 'GET',
        raw_path => '/minimal',
        headers => [],
    };
    my $minimal_req = PAGI::Request->new($minimal_scope);
    is($minimal_req->raw_path, '/minimal', 'minimal request: raw_path works');
    is($minimal_req->query_string, '', 'minimal request: query_string defaults');
    is($minimal_req->scheme, 'http', 'minimal request: scheme defaults');
    is($minimal_req->http_version, '1.1', 'minimal request: http_version defaults');
};

subtest 'on_disconnect returns $self for chaining' => sub {
    my $scope = { type => 'http', method => 'GET', headers => [] };
    my $req = PAGI::Request->new($scope);

    # No connection — early-return path must still return $self
    is $req->on_disconnect(sub {}), $req,
        'on_disconnect returns $self when no connection';

    # Chain on_disconnect with a sync accessor
    my $scope2 = { type => 'http', method => 'GET', headers => [], query_string => 'x=1' };
    my $req2 = PAGI::Request->new($scope2);
    is $req2->on_disconnect(sub {})->query_param('x'), '1',
        'on_disconnect chains with query_param';
};

subtest 'on_disconnect with connection returns $self' => sub {
    {
        package t::MockConn;
        sub new { bless { cbs => [] }, shift }
        sub on_disconnect {
            my ($self, $cb) = @_;
            push @{$self->{cbs}}, $cb;
        }
    }

    my $conn = t::MockConn->new;
    my $scope = { type => 'http', method => 'GET', headers => [],
                  'pagi.connection' => $conn };
    my $req = PAGI::Request->new($scope);

    is $req->on_disconnect(sub {}), $req,
        'on_disconnect returns $self when connection is present';
    is scalar @{$conn->{cbs}}, 1, 'callback was delegated to connection';
};

subtest 'headers as Hash::MultiValue' => sub {
    my $scope = {
        type    => 'http',
        method  => 'GET',
        headers => [
            ['Accept', 'text/html'],
            ['Accept', 'application/json'],
            ['Content-Type', 'text/plain'],
            ['X-Custom', 'value1'],
        ],
    };

    my $req = PAGI::Request->new($scope);

    # headers returns Hash::MultiValue
    my $headers = $req->headers;
    isa_ok $headers, 'Hash::MultiValue';

    # Single value access (last value - keys are normalized to lowercase)
    is($headers->get('accept'), 'application/json', 'get returns last value');
    is($headers->get('content-type'), 'text/plain', 'access other headers');

    # Multi-value access
    my @accepts = $headers->get_all('accept');
    is(\@accepts, ['text/html', 'application/json'], 'get_all returns all values');

    # header_all method
    my @accepts2 = $req->header_all('accept');
    is(\@accepts2, ['text/html', 'application/json'], 'header_all works');
};

done_testing;
