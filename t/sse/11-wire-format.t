#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use IO::Async::Stream;
use IO::Socket::INET;
use Future::AsyncAwait;
use Future;
use FindBin;

use lib "$FindBin::Bin/../../lib";
use PAGI::Server;

plan skip_all => "Server integration tests not supported on Windows"
    if $^O eq 'MSWin32';

# SSE app that sends events with various line endings
# The $test_data variable is set per-subtest to control what data is sent
my $test_data;
my $test_comment;

my $app = async sub {
    my ($scope, $receive, $send) = @_;

    if ($scope->{type} eq 'lifespan') {
        my $event = await $receive->();
        await $send->({ type => 'lifespan.startup.complete' })
            if $event->{type} eq 'lifespan.startup';
        $event = await $receive->();
        await $send->({ type => 'lifespan.shutdown.complete' })
            if $event && $event->{type} eq 'lifespan.shutdown';
        return;
    }

    if ($scope->{type} eq 'sse') {
        await $send->({
            type    => 'sse.start',
            status  => 200,
            headers => [],
        });

        if (defined $test_data) {
            await $send->({
                type => 'sse.send',
                data => $test_data,
            });
        }

        if (defined $test_comment) {
            await $send->({
                type    => 'sse.comment',
                comment => $test_comment,
            });
        }

        return;
    }

    # Fall through for HTTP
    await $send->({
        type    => 'http.response.start',
        status  => 404,
        headers => [['content-type', 'text/plain']],
    });
    await $send->({
        type => 'http.response.body',
        body => 'not found',
        more => 0,
    });
};

# Helper: connect to server, send SSE request, read full response
async sub sse_raw_get {
    my ($loop, $port) = @_;

    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
    ) or die "Cannot connect: $!";

    my $response = '';
    my $done = $loop->new_future;

    my $stream = IO::Async::Stream->new(
        handle    => $sock,
        on_read   => sub {
            my ($self, $buffref, $eof) = @_;
            $response .= $$buffref;
            $$buffref = '';
            if ($eof) {
                $done->done($response) unless $done->is_ready;
            }
            return 0;
        },
        on_read_eof => sub {
            $done->done($response) unless $done->is_ready;
        },
    );

    $loop->add($stream);
    $stream->write(
        "GET /events HTTP/1.1\r\n"
        . "Host: localhost\r\n"
        . "Accept: text/event-stream\r\n"
        . "Connection: close\r\n"
        . "\r\n"
    );

    my $timeout = $loop->timeout_future(after => 5);
    await Future->wait_any($done, $timeout);

    $loop->remove($stream);
    return $response;
}

# Helper: extract SSE body from chunked HTTP response
sub extract_sse_body {
    my ($raw) = @_;
    # Split on the blank line between headers and body
    my ($headers, $body) = split /\r\n\r\n/, $raw, 2;
    return '' unless defined $body;

    # Decode chunked transfer encoding
    my $decoded = '';
    while ($body =~ /\G([0-9a-fA-F]+)\r\n/gc) {
        my $len = hex($1);
        last if $len == 0;
        $decoded .= substr($body, pos($body), $len);
        pos($body) += $len;
        # Skip trailing \r\n after chunk data
        pos($body) += 2 if substr($body, pos($body), 2) eq "\r\n";
    }
    return $decoded;
}

my $loop = IO::Async::Loop->new;

# Test 1: LF line endings in data (baseline - should already work)
subtest 'Data with LF line endings produces correct wire format' => sub {
    $test_data = "line1\nline2\nline3";
    $test_comment = undef;

    my $server = PAGI::Server->new(
        app        => $app,
        host       => '127.0.0.1',
        port       => 0,
        quiet      => 1,
        access_log => undef,
    );

    $loop->add($server);
    $server->listen->get;

    my $response = sse_raw_get($loop, $server->port)->get;
    my $body = extract_sse_body($response);

    like($body, qr/data: line1\n/, 'line1 has data: prefix');
    like($body, qr/data: line2\n/, 'line2 has data: prefix');
    like($body, qr/data: line3\n/, 'line3 has data: prefix');

    # Verify no \r leaking into data fields
    unlike($body, qr/data: [^\n]*\r/, 'no CR leaking into data fields');

    $server->shutdown->get;
    $loop->remove($server);
};

# Test 2: CRLF line endings in data
subtest 'Data with CRLF line endings produces correct wire format' => sub {
    $test_data = "line1\r\nline2\r\nline3";
    $test_comment = undef;

    my $server = PAGI::Server->new(
        app        => $app,
        host       => '127.0.0.1',
        port       => 0,
        quiet      => 1,
        access_log => undef,
    );

    $loop->add($server);
    $server->listen->get;

    my $response = sse_raw_get($loop, $server->port)->get;
    my $body = extract_sse_body($response);

    like($body, qr/data: line1\n/, 'line1 has data: prefix');
    like($body, qr/data: line2\n/, 'line2 has data: prefix');
    like($body, qr/data: line3\n/, 'line3 has data: prefix');

    # No \r in data fields
    unlike($body, qr/data: [^\n]*\r/, 'no CR leaking into data fields');

    $server->shutdown->get;
    $loop->remove($server);
};

# Test 3: Bare CR line endings in data (old Mac style)
subtest 'Data with bare CR line endings produces correct wire format' => sub {
    $test_data = "line1\rline2\rline3";
    $test_comment = undef;

    my $server = PAGI::Server->new(
        app        => $app,
        host       => '127.0.0.1',
        port       => 0,
        quiet      => 1,
        access_log => undef,
    );

    $loop->add($server);
    $server->listen->get;

    my $response = sse_raw_get($loop, $server->port)->get;
    my $body = extract_sse_body($response);

    like($body, qr/data: line1\n/, 'line1 has data: prefix');
    like($body, qr/data: line2\n/, 'line2 has data: prefix');
    like($body, qr/data: line3\n/, 'line3 has data: prefix');

    # No \r in data fields
    unlike($body, qr/data: [^\n]*\r/, 'no CR leaking into data fields');

    $server->shutdown->get;
    $loop->remove($server);
};

# Test 4: Mixed line endings
subtest 'Data with mixed line endings produces correct wire format' => sub {
    $test_data = "lf-line\ncrlf-line\r\ncr-line\rlast";
    $test_comment = undef;

    my $server = PAGI::Server->new(
        app        => $app,
        host       => '127.0.0.1',
        port       => 0,
        quiet      => 1,
        access_log => undef,
    );

    $loop->add($server);
    $server->listen->get;

    my $response = sse_raw_get($loop, $server->port)->get;
    my $body = extract_sse_body($response);

    like($body, qr/data: lf-line\n/, 'LF-terminated line correct');
    like($body, qr/data: crlf-line\n/, 'CRLF-terminated line correct');
    like($body, qr/data: cr-line\n/, 'CR-terminated line correct');
    like($body, qr/data: last\n/, 'last line correct');

    unlike($body, qr/data: [^\n]*\r/, 'no CR leaking into data fields');

    $server->shutdown->get;
    $loop->remove($server);
};

# Test 5: Multi-line comment
subtest 'Multi-line comment has each line prefixed with colon' => sub {
    $test_data = undef;
    $test_comment = "line1\nline2\nline3";

    my $server = PAGI::Server->new(
        app        => $app,
        host       => '127.0.0.1',
        port       => 0,
        quiet      => 1,
        access_log => undef,
    );

    $loop->add($server);
    $server->listen->get;

    my $response = sse_raw_get($loop, $server->port)->get;
    my $body = extract_sse_body($response);

    like($body, qr/:line1\n/, 'comment line1 prefixed with colon');
    like($body, qr/:line2\n/, 'comment line2 prefixed with colon');
    like($body, qr/:line3\n/, 'comment line3 prefixed with colon');

    $server->shutdown->get;
    $loop->remove($server);
};

# Test 6: Multi-line comment with CRLF
subtest 'Multi-line comment with CRLF line endings' => sub {
    $test_data = undef;
    $test_comment = "line1\r\nline2\r\nline3";

    my $server = PAGI::Server->new(
        app        => $app,
        host       => '127.0.0.1',
        port       => 0,
        quiet      => 1,
        access_log => undef,
    );

    $loop->add($server);
    $server->listen->get;

    my $response = sse_raw_get($loop, $server->port)->get;
    my $body = extract_sse_body($response);

    like($body, qr/:line1\n/, 'comment line1 prefixed with colon');
    like($body, qr/:line2\n/, 'comment line2 prefixed with colon');
    like($body, qr/:line3\n/, 'comment line3 prefixed with colon');

    unlike($body, qr/:[^\n]*\r/, 'no CR leaking into comment lines');

    $server->shutdown->get;
    $loop->remove($server);
};

done_testing;
