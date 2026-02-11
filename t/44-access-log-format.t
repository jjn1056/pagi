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

# --- Step 2: Format string compiler ---

# Helper to compile a format and invoke with test data
sub compile_and_format {
    my ($format, %overrides) = @_;

    my $formatter = PAGI::Server->_compile_access_log_format($format);

    my $info = {
        client_ip       => '192.168.1.1',
        timestamp       => '10/Feb/2026:12:34:56 +0000',
        method          => 'GET',
        path            => '/test/path',
        query           => 'foo=bar',
        http_version    => '1.1',
        status          => 200,
        size            => 1234,
        duration        => 0.123456,
        request_headers => [
            ['host', 'example.com'],
            ['user-agent', 'TestBot/1.0'],
            ['referer', 'http://example.com/'],
        ],
        %overrides,
    };

    return $formatter->($info);
}

subtest 'Format compiler: individual atoms' => sub {
    is(compile_and_format('%h'), '192.168.1.1', '%h returns client IP');
    is(compile_and_format('%s'), '200', '%s returns status code');
    is(compile_and_format('%r'), 'GET /test/path HTTP/1.1', '%r returns request line');
    is(compile_and_format('%m'), 'GET', '%m returns method');
    is(compile_and_format('%U'), '/test/path', '%U returns URL path');
    is(compile_and_format('%q'), '?foo=bar', '%q returns ?query');
    is(compile_and_format('%q', query => ''), '', '%q returns empty when no query');
    is(compile_and_format('%q', query => undef), '', '%q returns empty when undef query');
    is(compile_and_format('%H'), 'HTTP/1.1', '%H returns protocol');
    is(compile_and_format('%l'), '-', '%l always returns -');
    is(compile_and_format('%u'), '-', '%u always returns -');
    is(compile_and_format('%t'), '10/Feb/2026:12:34:56 +0000', '%t returns CLF timestamp');

    # Size atoms
    is(compile_and_format('%b'), '1234', '%b returns size');
    is(compile_and_format('%b', size => 0), '-', '%b returns - when size is 0');
    is(compile_and_format('%B'), '1234', '%B returns size');
    is(compile_and_format('%B', size => 0), '0', '%B returns 0 when size is 0');

    # Duration atoms
    my $result_D = compile_and_format('%D');
    like($result_D, qr/^\d+$/, '%D returns integer microseconds');
    is($result_D, '123456', '%D returns 123456 microseconds for 0.123456s');

    my $result_T = compile_and_format('%T');
    is($result_T, '0', '%T returns 0 for 0.123456s (integer seconds)');
    is(compile_and_format('%T', duration => 2.7), '2', '%T returns 2 for 2.7s');
};

subtest 'Format compiler: header extraction' => sub {
    is(compile_and_format('%{User-Agent}i'), 'TestBot/1.0', '%{User-Agent}i extracts header');
    is(compile_and_format('%{Referer}i'), 'http://example.com/', '%{Referer}i extracts header');
    is(compile_and_format('%{Host}i'), 'example.com', '%{Host}i extracts header');
    is(compile_and_format('%{X-Missing}i'), '-', '%{X-Missing}i returns - for missing header');

    # Case-insensitive header matching
    is(compile_and_format('%{user-agent}i'), 'TestBot/1.0', 'header matching is case-insensitive');
};

subtest 'Format compiler: literal text and escapes' => sub {
    is(compile_and_format('[%t] %h'), '[10/Feb/2026:12:34:56 +0000] 192.168.1.1',
        'Literal text preserved around atoms');
    is(compile_and_format('%%'), '%', '%% produces literal percent');
    is(compile_and_format('start %h middle %s end'), 'start 192.168.1.1 middle 200 end',
        'Multiple atoms with literal text');
};

subtest 'Format compiler: named presets' => sub {
    # CLF preset should match current default output format
    my $clf = compile_and_format('clf');
    like($clf, qr/^192\.168\.1\.1 - - \[/, 'CLF preset starts with IP and dashes');
    like($clf, qr/"GET \/test\/path HTTP\/1\.1"/, 'CLF preset contains quoted request line');
    like($clf, qr/200 \d+s$/, 'CLF preset ends with status and duration');

    # Combined preset
    my $combined = compile_and_format('combined');
    like($combined, qr/^192\.168\.1\.1 - -/, 'combined starts with IP');
    like($combined, qr/"http:\/\/example\.com\/"/, 'combined contains Referer');
    like($combined, qr/"TestBot\/1\.0"/, 'combined contains User-Agent');

    # Common preset
    my $common = compile_and_format('common');
    like($common, qr/^192\.168\.1\.1 - - \[/, 'common starts with IP and dashes');
    like($common, qr/\b1234\b/, 'common contains response size');

    # Tiny preset
    my $tiny = compile_and_format('tiny');
    like($tiny, qr/^GET/, 'tiny starts with method');
    like($tiny, qr/\/test\/path\?foo=bar/, 'tiny contains path with query');
    like($tiny, qr/200/, 'tiny contains status');
    like($tiny, qr/\d+ms$/, 'tiny ends with duration in ms');
};

subtest 'Format compiler: unknown atom dies' => sub {
    like(
        dies { PAGI::Server->_compile_access_log_format('%Z') },
        qr/Unknown access log format atom '%Z'/,
        'Unknown atom %Z produces helpful error'
    );
};

done_testing;
