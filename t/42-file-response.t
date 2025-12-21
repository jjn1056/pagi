#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use Net::Async::HTTP;
use File::Temp qw(tempdir);
use Future::AsyncAwait;

use PAGI::Server;

# Create shared event loop and HTTP client
my $loop = IO::Async::Loop->new;
my $http = Net::Async::HTTP->new;
$loop->add($http);

# Create test files
my $tempdir = tempdir(CLEANUP => 1);
my $test_content = "Hello from file response!\n" x 100;  # ~2.7KB
my $test_file = "$tempdir/test.txt";
open my $fh, '>:raw', $test_file or die "Cannot create test file: $!";
print $fh $test_content;
close $fh;

my $binary_content = pack("C*", 0..255) x 10;  # 2560 bytes
my $binary_file = "$tempdir/binary.bin";
open $fh, '>:raw', $binary_file or die;
print $fh $binary_content;
close $fh;

# Large file for chunked transfer / worker pool testing
my $large_content = "X" x (128 * 1024);  # 128KB to exceed chunk size
my $large_file = "$tempdir/large.bin";
open $fh, '>:raw', $large_file or die;
print $fh $large_content;
close $fh;

# Helper to create a basic app that handles lifespan
sub make_app {
    my ($handler) = @_;

    return async sub  {
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
        await $handler->($scope, $receive, $send);
    };
}

# Helper to run a server test
sub with_server {
    my ($app, $test) = @_;

    my $server = PAGI::Server->new(
        app => make_app($app),
        host => '127.0.0.1',
        port => 0,
        quiet => 1,
    );
    $loop->add($server);
    $server->listen->get;
    my $port = $server->port;

    eval { $test->($port, $server) };
    my $err = $@;

    $server->shutdown->get;
    $loop->remove($server);

    die $err if $err;
}

subtest 'file response sends full file (with Content-Length - sendfile path)' => sub {
    with_server(
        async sub  {
        my ($scope, $receive, $send) = @_;
            await $send->({
                type => 'http.response.start',
                status => 200,
                headers => [
                    ['content-type', 'text/plain'],
                    ['content-length', length($test_content)],
                ],
            });
            await $send->({
                type => 'http.response.body',
                file => $test_file,
            });
        },
        sub  {
        my ($port, $server) = @_;
            my $response = $http->GET("http://127.0.0.1:$port/test.txt")->get;
            is($response->code, 200, 'got 200 response');
            is($response->content, $test_content, 'file content matches');
            is(length($response->content), length($test_content), 'content length matches');
        }
    );
};

subtest 'file response with chunked encoding (worker pool path)' => sub {
    # No Content-Length = chunked encoding = can't use sendfile = worker pool
    with_server(
        async sub  {
        my ($scope, $receive, $send) = @_;
            await $send->({
                type => 'http.response.start',
                status => 200,
                headers => [
                    ['content-type', 'text/plain'],
                    # No content-length, so chunked encoding will be used
                ],
            });
            await $send->({
                type => 'http.response.body',
                file => $test_file,
            });
        },
        sub  {
        my ($port, $server) = @_;
            my $response = $http->GET("http://127.0.0.1:$port/test.txt")->get;
            is($response->code, 200, 'got 200 response');
            is($response->content, $test_content, 'file content matches with chunked encoding');
        }
    );
};

subtest 'file response with offset and length (Range request simulation)' => sub {
    my $offset = 100;
    my $length = 500;
    my $expected = substr($test_content, $offset, $length);

    with_server(
        async sub  {
        my ($scope, $receive, $send) = @_;
            await $send->({
                type => 'http.response.start',
                status => 206,
                headers => [
                    ['content-type', 'text/plain'],
                    ['content-length', $length],
                    ['content-range', "bytes $offset-" . ($offset + $length - 1) . "/" . length($test_content)],
                ],
            });
            await $send->({
                type => 'http.response.body',
                file => $test_file,
                offset => $offset,
                length => $length,
            });
        },
        sub  {
        my ($port, $server) = @_;
            my $response = $http->GET("http://127.0.0.1:$port/test.txt")->get;
            is($response->code, 206, 'got 206 Partial Content');
            is($response->content, $expected, 'partial content matches');
            is(length($response->content), $length, 'partial content length correct');
        }
    );
};

subtest 'file response offset at end of file' => sub {
    my $offset = length($test_content) - 50;
    my $expected = substr($test_content, $offset);

    with_server(
        async sub  {
        my ($scope, $receive, $send) = @_;
            await $send->({
                type => 'http.response.start',
                status => 206,
                headers => [
                    ['content-type', 'text/plain'],
                    ['content-length', length($expected)],
                ],
            });
            await $send->({
                type => 'http.response.body',
                file => $test_file,
                offset => $offset,
                # No length = read to EOF
            });
        },
        sub  {
        my ($port, $server) = @_;
            my $response = $http->GET("http://127.0.0.1:$port/test.txt")->get;
            is($response->code, 206, 'got 206 response');
            is($response->content, $expected, 'content from offset to EOF matches');
        }
    );
};

subtest 'fh response sends from filehandle' => sub {
    with_server(
        async sub  {
        my ($scope, $receive, $send) = @_;
            open my $fh, '<:raw', $test_file or die "Cannot open: $!";

            await $send->({
                type => 'http.response.start',
                status => 200,
                headers => [
                    ['content-type', 'text/plain'],
                    ['content-length', length($test_content)],
                ],
            });
            await $send->({
                type => 'http.response.body',
                fh => $fh,
                length => length($test_content),
            });

            close $fh;
        },
        sub  {
        my ($port, $server) = @_;
            my $response = $http->GET("http://127.0.0.1:$port/")->get;
            is($response->code, 200, 'got 200 response');
            is($response->content, $test_content, 'filehandle content matches');
        }
    );
};

subtest 'fh response with offset (seek)' => sub {
    my $offset = 200;
    my $length = 300;
    my $expected = substr($test_content, $offset, $length);

    with_server(
        async sub  {
        my ($scope, $receive, $send) = @_;
            open my $fh, '<:raw', $test_file or die "Cannot open: $!";

            await $send->({
                type => 'http.response.start',
                status => 200,
                headers => [
                    ['content-type', 'text/plain'],
                    ['content-length', $length],
                ],
            });
            await $send->({
                type => 'http.response.body',
                fh => $fh,
                offset => $offset,
                length => $length,
            });

            close $fh;
        },
        sub  {
        my ($port, $server) = @_;
            my $response = $http->GET("http://127.0.0.1:$port/")->get;
            is($response->code, 200, 'got 200 response');
            is($response->content, $expected, 'fh with offset content matches');
        }
    );
};

subtest 'binary file response preserves bytes' => sub {
    with_server(
        async sub  {
        my ($scope, $receive, $send) = @_;
            await $send->({
                type => 'http.response.start',
                status => 200,
                headers => [
                    ['content-type', 'application/octet-stream'],
                    ['content-length', length($binary_content)],
                ],
            });
            await $send->({
                type => 'http.response.body',
                file => $binary_file,
            });
        },
        sub  {
        my ($port, $server) = @_;
            my $response = $http->GET("http://127.0.0.1:$port/binary.bin")->get;
            is($response->code, 200, 'got 200 response');
            is(length($response->content), length($binary_content), 'binary length matches');
            is($response->content, $binary_content, 'binary content matches byte-for-byte');
        }
    );
};

subtest 'large file streams correctly (tests chunking)' => sub {
    with_server(
        async sub  {
        my ($scope, $receive, $send) = @_;
            await $send->({
                type => 'http.response.start',
                status => 200,
                headers => [
                    ['content-type', 'application/octet-stream'],
                    ['content-length', length($large_content)],
                ],
            });
            await $send->({
                type => 'http.response.body',
                file => $large_file,
            });
        },
        sub  {
        my ($port, $server) = @_;
            my $response = $http->GET("http://127.0.0.1:$port/large.bin")->get;
            is($response->code, 200, 'got 200 response');
            is(length($response->content), length($large_content), 'large file length matches');
            is($response->content, $large_content, 'large file content matches');
        }
    );
};

subtest 'large file with chunked encoding' => sub {
    # Force chunked encoding (worker pool path) with large file
    with_server(
        async sub  {
        my ($scope, $receive, $send) = @_;
            await $send->({
                type => 'http.response.start',
                status => 200,
                headers => [
                    ['content-type', 'application/octet-stream'],
                    # No content-length = chunked
                ],
            });
            await $send->({
                type => 'http.response.body',
                file => $large_file,
            });
        },
        sub  {
        my ($port, $server) = @_;
            my $response = $http->GET("http://127.0.0.1:$port/large.bin")->get;
            is($response->code, 200, 'got 200 response');
            is(length($response->content), length($large_content), 'large file length matches (chunked)');
            is($response->content, $large_content, 'large file content matches (chunked)');
        }
    );
};

subtest 'file not found dies with error' => sub {
    my $error_caught = 0;
    my $error_message = '';

    with_server(
        async sub  {
        my ($scope, $receive, $send) = @_;
            # Don't start a response until we know the file exists
            # Test that the file operation fails properly
            eval {
                # Try to stat the file first (this will fail)
                my $file = '/nonexistent/file/that/does/not/exist.txt';
                die "File not found: $file" unless -f $file;

                await $send->({
                    type => 'http.response.start',
                    status => 200,
                    headers => [['content-length', 100]],
                });
                await $send->({
                    type => 'http.response.body',
                    file => $file,
                });
            };
            if ($@) {
                $error_caught = 1;
                $error_message = $@;
                # Send proper error response
                my $body = 'File not found';
                await $send->({
                    type => 'http.response.start',
                    status => 404,
                    headers => [
                        ['content-type', 'text/plain'],
                        ['content-length', length($body)],
                    ],
                });
                await $send->({
                    type => 'http.response.body',
                    body => $body,
                    more => 0,
                });
            }
        },
        sub  {
        my ($port, $server) = @_;
            my $response = $http->GET("http://127.0.0.1:$port/")->get;
            is($response->code, 404, 'got 404 for missing file');
            ok($server->is_running, 'server still running after file error');
        }
    );

    ok($error_caught, 'error was caught for nonexistent file');
    like($error_message, qr/File not found/, 'error message mentions file not found');
};

subtest 'zero-length file works' => sub {
    my $empty_file = "$tempdir/empty.txt";
    open $fh, '>:raw', $empty_file or die;
    close $fh;

    with_server(
        async sub  {
        my ($scope, $receive, $send) = @_;
            await $send->({
                type => 'http.response.start',
                status => 200,
                headers => [
                    ['content-type', 'text/plain'],
                    ['content-length', 0],
                ],
            });
            await $send->({
                type => 'http.response.body',
                file => $empty_file,
            });
        },
        sub  {
        my ($port, $server) = @_;
            my $response = $http->GET("http://127.0.0.1:$port/empty.txt")->get;
            is($response->code, 200, 'got 200 response');
            is($response->content, '', 'empty file returns empty content');
            is(length($response->content), 0, 'content length is 0');
        }
    );
};

done_testing;
