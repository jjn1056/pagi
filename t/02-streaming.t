use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use IO::Async::Loop;
use Net::Async::HTTP;
use Future::AsyncAwait;

use PAGI::Server;

# Step 2: Streaming Responses and Disconnect Handling
# Tests for examples/02-streaming-response/app.pl

my $loop = IO::Async::Loop->new;

# Test 1: Streaming response with multiple chunks
subtest 'Streaming response uses chunked Transfer-Encoding' => sub {
    my $simple_streaming_app = async sub ($scope, $receive, $send) {
        die "Unsupported: $scope->{type}" if $scope->{type} ne 'http';

        while (1) {
            my $event = await $receive->();
            last if $event->{type} ne 'http.request';
            last unless $event->{more};
        }

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({ type => 'http.response.body', body => "Chunk 1\n", more => 1 });
        await $send->({ type => 'http.response.body', body => "Chunk 2\n", more => 1 });
        await $send->({ type => 'http.response.body', body => "Chunk 3\n", more => 0 });
    };

    my $server = PAGI::Server->new(
        app   => $simple_streaming_app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;

    my $http = Net::Async::HTTP->new;
    $loop->add($http);

    my $response = $http->GET("http://127.0.0.1:$port/")->get;

    is($response->code, 200, 'Response status is 200 OK');
    is($response->header('Transfer-Encoding'), 'chunked', 'Response uses chunked Transfer-Encoding');

    my $body = $response->decoded_content;
    like($body, qr/Chunk 1.*Chunk 2.*Chunk 3/s, 'Response body contains all chunks in order');

    $server->shutdown->get;
    $loop->remove($server);
};

# Test 2: Multiple body chunks arrive in order
subtest 'Multiple http.response.body events work correctly' => sub {
    my $streaming_app = async sub ($scope, $receive, $send) {
        die "Unsupported: $scope->{type}" if $scope->{type} ne 'http';

        while (1) {
            my $event = await $receive->();
            last if $event->{type} ne 'http.request';
            last unless $event->{more};
        }

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({ type => 'http.response.body', body => "First\n", more => 1 });
        await $send->({ type => 'http.response.body', body => "Second\n", more => 1 });
        await $send->({ type => 'http.response.body', body => "Third\n", more => 0 });
    };

    my $server = PAGI::Server->new(
        app   => $streaming_app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;

    my $http = Net::Async::HTTP->new;
    $loop->add($http);

    my $response = $http->GET("http://127.0.0.1:$port/")->get;

    is($response->code, 200, 'Response status is 200');
    my $body = $response->decoded_content;
    like($body, qr/First\nSecond\nThird\n/, 'Body contains all chunks in order');

    $server->shutdown->get;
    $loop->remove($server);
};

# Test 3: Streaming without trailers terminates correctly
subtest 'Streaming without trailers terminates correctly' => sub {
    my $no_trailer_app = async sub ($scope, $receive, $send) {
        die "Unsupported: $scope->{type}" if $scope->{type} ne 'http';

        while (1) {
            my $event = await $receive->();
            last if $event->{type} ne 'http.request';
            last unless $event->{more};
        }

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({ type => 'http.response.body', body => "Data 1\n", more => 1 });
        await $send->({ type => 'http.response.body', body => "Data 2\n", more => 0 });
    };

    my $server = PAGI::Server->new(
        app   => $no_trailer_app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;

    my $http = Net::Async::HTTP->new;
    $loop->add($http);

    my $response = $http->GET("http://127.0.0.1:$port/")->get;

    is($response->code, 200, 'Response status is 200');
    is($response->header('Transfer-Encoding'), 'chunked', 'Response uses chunked encoding');
    my $body = $response->decoded_content;
    like($body, qr/Data 1\nData 2\n/, 'Body contains all data');

    $server->shutdown->get;
    $loop->remove($server);
};

# Test 4: Streaming with trailers (verify body content)
# Note: Net::Async::HTTP doesn't easily expose trailers, but we verify the body
# Trailers are verified manually with: curl -s -D - http://localhost:5000/
subtest 'Streaming with trailers - body content correct' => sub {
    my $trailer_app = async sub ($scope, $receive, $send) {
        die "Unsupported: $scope->{type}" if $scope->{type} ne 'http';

        while (1) {
            my $event = await $receive->();
            last if $event->{type} ne 'http.request';
            last unless $event->{more};
        }

        await $send->({
            type     => 'http.response.start',
            status   => 200,
            headers  => [['content-type', 'text/plain']],
            trailers => 1,
        });

        await $send->({ type => 'http.response.body', body => "Body content\n", more => 0 });

        await $send->({
            type    => 'http.response.trailers',
            headers => [['x-test-trailer', 'trailer-value']],
        });
    };

    my $server = PAGI::Server->new(
        app   => $trailer_app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;

    my $http = Net::Async::HTTP->new;
    $loop->add($http);

    my $response = $http->GET("http://127.0.0.1:$port/")->get;

    is($response->code, 200, 'Response status is 200');
    is($response->header('Transfer-Encoding'), 'chunked', 'Response uses chunked encoding');
    my $body = $response->decoded_content;
    like($body, qr/Body content/, 'Body content is correct');

    $server->shutdown->get;
    $loop->remove($server);
};

done_testing;
