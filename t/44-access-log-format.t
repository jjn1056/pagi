use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use Net::Async::HTTP;
use Future::AsyncAwait;
use FindBin;
use URI;

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
        app               => $hello_app,
        host              => '127.0.0.1',
        port              => 0,
        access_log        => $log_fh,
        access_log_format => '%s %b',
        quiet             => 1,
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

    # "Hello, World!" = 13 bytes; format: "status size"
    like($log_output, qr/^200 13$/m, 'Access log contains response size of 13 bytes');

    $loop->remove($http);
    $server->shutdown->get;
    $loop->remove($server);
};

subtest 'Response size accumulates across chunks' => sub {
    my $log_output = '';
    open(my $log_fh, '>', \$log_output) or die "Cannot create in-memory log: $!";

    my $server = PAGI::Server->new(
        app               => $chunked_app,
        host              => '127.0.0.1',
        port              => 0,
        access_log        => $log_fh,
        access_log_format => '%s %b',
        quiet             => 1,
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
    like($log_output, qr/^200 12$/m, 'Access log contains accumulated size of 12 bytes');

    $loop->remove($http);
    $server->shutdown->get;
    $loop->remove($server);
};

subtest 'Response size resets between keep-alive requests' => sub {
    my $log_output = '';
    open(my $log_fh, '>', \$log_output) or die "Cannot create in-memory log: $!";

    my $server = PAGI::Server->new(
        app               => $hello_app,
        host              => '127.0.0.1',
        port              => 0,
        access_log        => $log_fh,
        access_log_format => '%s %b',
        quiet             => 1,
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
        is($lines[$i], '200 13', "Request " . ($i+1) . " shows 13 bytes (reset between requests)");
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
    is(compile_and_format('%r'), 'GET /test/path?foo=bar HTTP/1.1', '%r returns full request line with query');
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
    is(compile_and_format('%d'), '0.123', '%d returns seconds with 3 decimal places');
    is(compile_and_format('%d', duration => 2.7), '2.700', '%d returns 2.700 for 2.7s');

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
    # CLF preset matches the server's default output format
    my $clf = compile_and_format('clf');
    like($clf, qr/^192\.168\.1\.1 - - \[/, 'CLF preset starts with IP and dashes');
    like($clf, qr/"GET \/test\/path\?foo=bar"/, 'CLF preset contains quoted method/path/query');
    like($clf, qr/200 \d+\.\d+s$/, 'CLF preset ends with status and duration in seconds');

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

# --- Step 3: Integration tests (real server with format options) ---

# App that echoes back with known headers for combined format testing
my $echo_app = async sub {
    my ($scope, $receive, $send) = @_;
    die "Unsupported scope type: $scope->{type}" if $scope->{type} ne 'http';

    await $send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [['content-type', 'text/plain']],
    });
    await $send->({
        type => 'http.response.body',
        body => 'OK',    # 2 bytes
    });
};

subtest 'Integration: combined format includes User-Agent and Referer' => sub {
    my $log_output = '';
    open(my $log_fh, '>', \$log_output) or die "Cannot create in-memory log: $!";

    my $server = PAGI::Server->new(
        app               => $echo_app,
        host              => '127.0.0.1',
        port              => 0,
        access_log        => $log_fh,
        access_log_format => 'combined',
        quiet             => 1,
    );

    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;
    my $http = Net::Async::HTTP->new;
    $loop->add($http);

    my $response = $http->do_request(
        method  => 'GET',
        uri     => URI->new("http://127.0.0.1:$port/test"),
        headers => {
            'Referer'    => 'http://example.com/',
            'User-Agent' => 'TestBot/2.0',
        },
    )->get;

    is($response->code, 200, 'Response is 200');

    close($log_fh);
    $loop->delay_future(after => 0.1)->get;

    like($log_output, qr/"TestBot\/2\.0"/, 'combined format includes User-Agent');
    like($log_output, qr/"http:\/\/example\.com\/"/, 'combined format includes Referer');
    like($log_output, qr/\b2\b/, 'combined format includes response size');

    $loop->remove($http);
    $server->shutdown->get;
    $loop->remove($server);
};

subtest 'Integration: tiny format is minimal' => sub {
    my $log_output = '';
    open(my $log_fh, '>', \$log_output) or die "Cannot create in-memory log: $!";

    my $server = PAGI::Server->new(
        app               => $echo_app,
        host              => '127.0.0.1',
        port              => 0,
        access_log        => $log_fh,
        access_log_format => 'tiny',
        quiet             => 1,
    );

    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;
    my $http = Net::Async::HTTP->new;
    $loop->add($http);

    my $response = $http->GET("http://127.0.0.1:$port/hello?x=1")->get;
    is($response->code, 200, 'Response is 200');

    close($log_fh);
    $loop->delay_future(after => 0.1)->get;

    like($log_output, qr/^GET \/hello\?x=1 200 \d+ms$/m, 'tiny format matches expected pattern');

    $loop->remove($http);
    $server->shutdown->get;
    $loop->remove($server);
};

subtest 'Integration: custom format string' => sub {
    my $log_output = '';
    open(my $log_fh, '>', \$log_output) or die "Cannot create in-memory log: $!";

    my $server = PAGI::Server->new(
        app               => $echo_app,
        host              => '127.0.0.1',
        port              => 0,
        access_log        => $log_fh,
        access_log_format => '%h %s %Dms',
        quiet             => 1,
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

    like($log_output, qr/^127\.0\.0\.1 200 \d+ms$/m, 'custom format matches expected pattern');

    $loop->remove($http);
    $server->shutdown->get;
    $loop->remove($server);
};

subtest 'Integration: default format matches CLF (backward compat)' => sub {
    my $log_output = '';
    open(my $log_fh, '>', \$log_output) or die "Cannot create in-memory log: $!";

    my $server = PAGI::Server->new(
        app        => $echo_app,
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

    my $response = $http->GET("http://127.0.0.1:$port/test")->get;
    is($response->code, 200, 'Response is 200');

    close($log_fh);
    $loop->delay_future(after => 0.1)->get;

    # CLF default format: IP - - [timestamp] "METHOD /path" status duration_in_seconds_s
    like($log_output,
        qr/^127\.0\.0\.1 - - \[\d{2}\/\w{3}\/\d{4}:\d{2}:\d{2}:\d{2} \+0000\] "GET \/test" 200 \d+\.\d+s$/m,
        'Default format matches CLF pattern');

    $loop->remove($http);
    $server->shutdown->get;
    $loop->remove($server);
};

subtest 'Integration: combined format has correct response size' => sub {
    my $log_output = '';
    open(my $log_fh, '>', \$log_output) or die "Cannot create in-memory log: $!";

    my $server = PAGI::Server->new(
        app               => $hello_app,
        host              => '127.0.0.1',
        port              => 0,
        access_log        => $log_fh,
        access_log_format => 'combined',
        quiet             => 1,
    );

    $loop->add($server);
    $server->listen->get;

    my $port = $server->port;
    my $http = Net::Async::HTTP->new;
    $loop->add($http);

    my $response = $http->GET("http://127.0.0.1:$port/")->get;
    is($response->code, 200, 'Response is 200');
    is($response->content, 'Hello, World!', 'Body is correct');

    close($log_fh);
    $loop->delay_future(after => 0.1)->get;

    # "Hello, World!" = 13 bytes
    like($log_output, qr/ 200 13 /, 'combined format shows correct 13-byte size');

    $loop->remove($http);
    $server->shutdown->get;
    $loop->remove($server);
};

subtest 'Format compiler: unknown atom dies' => sub {
    like(
        dies { PAGI::Server->_compile_access_log_format('%Z') },
        qr/Unknown access log format atom '%Z'/,
        'Unknown atom %Z produces helpful error'
    );
};

done_testing;
