#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;
use Net::Async::HTTP;
use JSON::MaybeXS;

use lib 'lib';
use PAGI::Server;
use PAGI::Request;

# Skip if not running integration tests
plan skip_all => 'Set INTEGRATION_TEST=1 to run' unless $ENV{INTEGRATION_TEST};

my $loop = IO::Async::Loop->new;

subtest 'full request/response cycle with PAGI::Request' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;

        if ($scope->{type} eq 'lifespan') {
            while (1) {
                my $event = await $receive->();
                if ($event->{type} eq 'lifespan.startup') {
                    await $send->({ type => 'lifespan.startup.complete' });
                }
                elsif ($event->{type} eq 'lifespan.shutdown') {
                    await $send->({ type => 'lifespan.shutdown.complete' });
                    last;
                }
            }
            return;
        }

        my $req = PAGI::Request->new($scope, $receive);

        my $response = {
            method       => $req->method,
            path         => $req->path,
            content_type => $req->content_type,
            is_json      => $req->is_json ? 1 : 0,
            query        => $req->query_param('foo'),
        };

        if ($req->is_post && $req->is_json) {
            my $json = await $req->json;
            $response->{body} = $json;
        }

        my $body = JSON::MaybeXS::encode_json($response);

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'application/json']],
        });
        await $send->({
            type => 'http.response.body',
            body => $body,
            more => 0,
        });
    };

    my $server = PAGI::Server->new(
        app   => $app,
        port  => 0,
        quiet => 1,
    );
    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;
    my $http = Net::Async::HTTP->new;
    $loop->add($http);

    # Test GET with query params
    my $res1 = $http->GET("http://127.0.0.1:$port/test?foo=bar")->get;
    is($res1->code, 200);
    my $data1 = JSON::MaybeXS::decode_json($res1->content);
    is($data1->{method}, 'GET');
    is($data1->{path}, '/test');
    is($data1->{query}, 'bar');

    # Test POST with JSON body
    my $req2 = HTTP::Request->new(
        POST => "http://127.0.0.1:$port/api",
        ['Content-Type' => 'application/json'],
        '{"name":"John","age":30}',
    );
    my $res2 = $http->do_request(request => $req2)->get;
    is($res2->code, 200);
    my $data2 = JSON::MaybeXS::decode_json($res2->content);
    is($data2->{is_json}, 1);
    is($data2->{body}, { name => 'John', age => 30 });

    $server->shutdown->get;
    $loop->remove($server);
    $loop->remove($http);
};

done_testing;
