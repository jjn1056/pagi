#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;

use lib 'lib';
use PAGI::Request;

subtest 'is_json predicate' => sub {
    my $json_scope = {
        type    => 'http',
        method  => 'POST',
        headers => [['content-type', 'application/json']],
    };
    my $json_charset = {
        type    => 'http',
        method  => 'POST',
        headers => [['content-type', 'application/json; charset=utf-8']],
    };
    my $html_scope = {
        type    => 'http',
        method  => 'GET',
        headers => [['content-type', 'text/html']],
    };

    ok(PAGI::Request->new($json_scope)->is_json, 'application/json is json');
    ok(PAGI::Request->new($json_charset)->is_json, 'with charset is json');
    ok(!PAGI::Request->new($html_scope)->is_json, 'text/html is not json');
};

subtest 'is_form predicate' => sub {
    my $urlencoded = {
        type    => 'http',
        method  => 'POST',
        headers => [['content-type', 'application/x-www-form-urlencoded']],
    };
    my $multipart = {
        type    => 'http',
        method  => 'POST',
        headers => [['content-type', 'multipart/form-data; boundary=----abc']],
    };
    my $json = {
        type    => 'http',
        method  => 'POST',
        headers => [['content-type', 'application/json']],
    };

    ok(PAGI::Request->new($urlencoded)->is_form, 'urlencoded is form');
    ok(PAGI::Request->new($multipart)->is_form, 'multipart is form');
    ok(!PAGI::Request->new($json)->is_form, 'json is not form');
};

subtest 'is_multipart predicate' => sub {
    my $multipart = {
        type    => 'http',
        method  => 'POST',
        headers => [['content-type', 'multipart/form-data; boundary=----abc']],
    };
    my $urlencoded = {
        type    => 'http',
        method  => 'POST',
        headers => [['content-type', 'application/x-www-form-urlencoded']],
    };

    ok(PAGI::Request->new($multipart)->is_multipart, 'multipart/form-data');
    ok(!PAGI::Request->new($urlencoded)->is_multipart, 'urlencoded is not multipart');
};

subtest 'accepts predicate' => sub {
    my $scope = {
        type    => 'http',
        method  => 'GET',
        headers => [
            ['accept', 'text/html'],
            ['accept', 'application/json'],
        ],
    };

    my $req = PAGI::Request->new($scope);

    ok($req->accepts('text/html'), 'accepts text/html');
    ok($req->accepts('application/json'), 'accepts application/json');
    ok(!$req->accepts('text/plain'), 'does not accept text/plain');
    ok($req->accepts('text/*'), 'accepts text/* wildcard');
    ok($req->accepts('*/*'), 'accepts */* wildcard');
};

subtest 'is_disconnected' => sub {
    require PAGI::Server::ConnectionState;

    # Test with client still connected
    my $conn1 = PAGI::Server::ConnectionState->new();
    my $scope1 = { type => 'http', method => 'GET', headers => [], 'pagi.connection' => $conn1 };
    my $req1 = PAGI::Request->new($scope1);
    ok(!$req1->is_disconnected, 'client connected');
    ok($req1->is_connected, 'is_connected returns true');

    # Test with disconnected client
    my $conn2 = PAGI::Server::ConnectionState->new();
    $conn2->_mark_disconnected('client_closed');
    my $scope2 = { type => 'http', method => 'GET', headers => [], 'pagi.connection' => $conn2 };
    my $req2 = PAGI::Request->new($scope2);
    ok($req2->is_disconnected, 'client disconnected');
    ok(!$req2->is_connected, 'is_connected returns false');
    is($req2->disconnect_reason, 'client_closed', 'disconnect_reason set');
};

done_testing;
