use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use Net::Async::HTTP;
use Future::AsyncAwait;
use FindBin;

use PAGI::Server;

plan skip_all => "Server integration tests not supported on Windows" if $^O eq 'MSWin32';

my $loop = IO::Async::Loop->new;

# --- Step 1: Response size tracking ---

# Simple app that returns a known-size body
my $hello_app = async sub {
    my ($scope, $receive, $send) = @_;
    die "Unsupported scope type: $scope->{type}" if $scope->{type} ne 'http';

    await $send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [['content-type', 'text/plain']],
    });
    await $send->({
        type => 'http.response.body',
        body => 'Hello, World!',    # 13 bytes
    });
};

# App that sends body in multiple chunks
my $chunked_app = async sub {
    my ($scope, $receive, $send) = @_;
    die "Unsupported scope type: $scope->{type}" if $scope->{type} ne 'http';

    await $send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [['content-type', 'text/plain']],
    });
    await $send->({
        type => 'http.response.body',
        body => 'chunk1',    # 6 bytes
        more => 1,
    });
    await $send->({
        type => 'http.response.body',
        body => 'chunk2',    # 6 bytes
        more => 0,
    });
};

subtest 'Response size tracked for single body' => sub {
    my $log_output = '';
    open(my $log_fh, '>', \$log_output) or die "Cannot create in-memory log: $!";

    my $server = PAGI::Server->new(
        app        => $hello_app,
        host       => '127.0.0.1',
        port       => 0,
        access_log => $log_fh,
        quiet      => 1,
    );

    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;
    my $http = Net::Async::HTTP->new;
    $loop->add($http);

    my $response = $http->GET("http://127.0.0.1:$port/")->get;
    is($response->code, 200, 'Response is 200');

    close($log_fh);
    $loop->delay_future(after => 0.1)->get;

    # The access log should contain the response size (13 bytes)
    like($log_output, qr/\b13\b/, 'Access log contains response size of 13 bytes');

    $loop->remove($http);
    $server->shutdown->get;
    $loop->remove($server);
};

subtest 'Response size accumulates across chunks' => sub {
    my $log_output = '';
    open(my $log_fh, '>', \$log_output) or die "Cannot create in-memory log: $!";

    my $server = PAGI::Server->new(
        app        => $chunked_app,
        host       => '127.0.0.1',
        port       => 0,
        access_log => $log_fh,
        quiet      => 1,
    );

    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;
    my $http = Net::Async::HTTP->new;
    $loop->add($http);

    my $response = $http->GET("http://127.0.0.1:$port/")->get;
    is($response->code, 200, 'Response is 200');
    is($response->content, 'chunk1chunk2', 'Got full chunked body');

    close($log_fh);
    $loop->delay_future(after => 0.1)->get;

    # Total: 6 + 6 = 12 bytes
    like($log_output, qr/\b12\b/, 'Access log contains accumulated size of 12 bytes');

    $loop->remove($http);
    $server->shutdown->get;
    $loop->remove($server);
};

subtest 'Response size resets between keep-alive requests' => sub {
    my $log_output = '';
    open(my $log_fh, '>', \$log_output) or die "Cannot create in-memory log: $!";

    my $server = PAGI::Server->new(
        app        => $hello_app,
        host       => '127.0.0.1',
        port       => 0,
        access_log => $log_fh,
        quiet      => 1,
    );

    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;
    my $http = Net::Async::HTTP->new;
    $loop->add($http);

    # Two requests on the same keep-alive connection
    my $response1 = $http->GET("http://127.0.0.1:$port/")->get;
    is($response1->code, 200, 'First response is 200');
    my $response2 = $http->GET("http://127.0.0.1:$port/")->get;
    is($response2->code, 200, 'Second response is 200');

    close($log_fh);
    $loop->delay_future(after => 0.1)->get;

    # Both log lines should show 13 bytes (not 26 from accumulation)
    my @lines = grep { /\S/ } split /\n/, $log_output;
    is(scalar @lines, 2, 'Two log lines for two requests');

    for my $i (0, 1) {
        like($lines[$i], qr/\b13\b/, "Request " . ($i+1) . " shows 13 bytes (reset between requests)");
    }

    $loop->remove($http);
    $server->shutdown->get;
    $loop->remove($server);
};

done_testing;
