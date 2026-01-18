#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use lib 'lib';
use PAGI::Request;

subtest 'query_params returns Hash::MultiValue' => sub {
    my $scope = {
        type         => 'http',
        method       => 'GET',
        query_string => 'foo=bar&baz=qux&foo=second',
        headers      => [],
    };

    my $req = PAGI::Request->new($scope);
    my $params = $req->query_params;

    isa_ok $params, 'Hash::MultiValue';
    is($params->get('foo'), 'second', 'get returns last value');
    is($params->get('baz'), 'qux', 'single value works');

    my @foos = $params->get_all('foo');
    is(\@foos, ['bar', 'second'], 'get_all returns all values');
};

subtest 'query_param() shortcut method' => sub {
    my $scope = {
        type         => 'http',
        method       => 'GET',
        query_string => 'page=5&tags=perl&tags=async',
        headers      => [],
    };

    my $req = PAGI::Request->new($scope);

    is($req->query_param('page'), '5', 'query returns single value');
    is($req->query_param('tags'), 'async', 'query returns last for multi');
    is($req->query_param('missing'), undef, 'query returns undef for missing');
};

subtest 'percent-decoding' => sub {
    my $scope = {
        type         => 'http',
        method       => 'GET',
        query_string => 'name=John%20Doe&emoji=%F0%9F%94%A5',
        headers      => [],
    };

    my $req = PAGI::Request->new($scope);

    is($req->query_param('name'), 'John Doe', 'spaces decoded');
    is($req->query_param('emoji'), "\x{1F525}", 'UTF-8 emoji decoded');
};

subtest 'empty and missing query string' => sub {
    my $scope1 = { type => 'http', method => 'GET', query_string => '', headers => [] };
    my $scope2 = { type => 'http', method => 'GET', headers => [] };

    my $req1 = PAGI::Request->new($scope1);
    my $req2 = PAGI::Request->new($scope2);

    isa_ok $req1->query_params, 'Hash::MultiValue';
    isa_ok $req2->query_params, 'Hash::MultiValue';

    is($req1->query_param('foo'), undef, 'missing key returns undef');
};

done_testing;
