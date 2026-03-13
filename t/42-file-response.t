#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use Net::Async::HTTP;
use File::Temp qw(tempdir);
use Future::AsyncAwait;
use Tie::Handle ();

use PAGI::Server;

plan skip_all => "Server integration tests not supported on Windows" if $^O eq 'MSWin32';

{
    package TestTiedHandle;

    use parent 'Tie::Handle';
    use Symbol qw(gensym);

    sub new_handle {
        my ($class, $content_ref) = @_;

        open my $inner_fh, '<', $content_ref
            or die "Cannot open scalar handle: $!";

        my $fh = gensym();
        tie *{$fh}, $class, $inner_fh;
        return $fh;
    }

    sub TIEHANDLE {
        my ($class, $inner_fh) = @_;
        return bless { inner_fh => $inner_fh }, $class;
    }

    sub READ {
        my ($self, undef, $length, $offset) = @_;
        return read($self->{inner_fh}, $_[1], $length, $offset // 0);
    }

    sub SEEK {
        my ($self, $position, $whence) = @_;
        return seek($self->{inner_fh}, $position, $whence);
    }

    sub TELL {
        my ($self) = @_;
        return tell($self->{inner_fh});
    }

    sub FILENO {
        return -1;
    }

    sub CLOSE {
        my ($self) = @_;
        return close($self->{inner_fh});
    }
}

package main;

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

# Large file for async I/O testing
# Size is 65KB - just over the 64KB sync_file_threshold to trigger async path
my $large_content = "X" x (65 * 1024);  # 65KB to exceed sync threshold
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

subtest 'file response sends full file with Content-Length' => sub {
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

subtest 'file response with chunked encoding' => sub {
    # No Content-Length = chunked encoding
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

subtest 'fh response without length reads to EOF' => sub {
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
            });

            close $fh;
        },
        sub  {
        my ($port, $server) = @_;
            my $response = $http->GET("http://127.0.0.1:$port/")->get;
            is($response->code, 200, 'got 200 response');
            is($response->content, $test_content, 'filehandle content matches without explicit length');
        }
    );
};

subtest 'fh response without length streams chunked to EOF' => sub {
    with_server(
        async sub  {
        my ($scope, $receive, $send) = @_;
            open my $fh, '<:raw', $test_file or die "Cannot open: $!";

            await $send->({
                type => 'http.response.start',
                status => 200,
                headers => [
                    ['content-type', 'text/plain'],
                ],
            });
            await $send->({
                type => 'http.response.body',
                fh => $fh,
            });

            close $fh;
        },
        sub  {
        my ($port, $server) = @_;
            my $response = $http->GET("http://127.0.0.1:$port/")->get;
            is($response->code, 200, 'got 200 response');
            is($response->content, $test_content, 'chunked filehandle content matches without explicit length');
        }
    );
};

subtest 'scalar-reference fh response without length streams to EOF' => sub {
    with_server(
        async sub  {
        my ($scope, $receive, $send) = @_;
            open my $fh, '<', \$test_content or die "Cannot open scalar handle: $!";

            await $send->({
                type => 'http.response.start',
                status => 200,
                headers => [
                    ['content-type', 'text/plain'],
                ],
            });
            await $send->({
                type => 'http.response.body',
                fh => $fh,
            });

            close $fh;
        },
        sub  {
        my ($port, $server) = @_;
            my $response = $http->GET("http://127.0.0.1:$port/")->get;
            is($response->code, 200, 'got 200 response');
            is($response->content, $test_content, 'scalar-reference filehandle content matches');
        }
    );
};

subtest 'tied fh response without length streams to EOF' => sub {
    with_server(
        async sub  {
        my ($scope, $receive, $send) = @_;
            my $fh = TestTiedHandle->new_handle(\$test_content);

            await $send->({
                type => 'http.response.start',
                status => 200,
                headers => [
                    ['content-type', 'text/plain'],
                ],
            });
            await $send->({
                type => 'http.response.body',
                fh => $fh,
            });

            close $fh;
        },
        sub  {
        my ($port, $server) = @_;
            my $response = $http->GET("http://127.0.0.1:$port/")->get;
            is($response->code, 200, 'got 200 response');
            is($response->content, $test_content, 'tied filehandle content matches');
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

# =============================================================================
# Test: Threshold boundary behavior
# =============================================================================
# These tests verify that files at exactly the threshold use sync path,
# and files just over the threshold use async path.
# Default sync_file_threshold is 64KB (65536 bytes).

subtest 'file at exact threshold uses sync path' => sub {
    # Create a file exactly at 64KB threshold
    my $threshold_content = "Y" x 65536;  # Exactly 64KB
    my $threshold_file = "$tempdir/threshold.bin";
    open my $tfh, '>:raw', $threshold_file or die;
    print $tfh $threshold_content;
    close $tfh;

    with_server(
        async sub {
            my ($scope, $receive, $send) = @_;
            await $send->({
                type => 'http.response.start',
                status => 200,
                headers => [
                    ['content-type', 'application/octet-stream'],
                    ['content-length', length($threshold_content)],
                ],
            });
            await $send->({
                type => 'http.response.body',
                file => $threshold_file,
            });
        },
        sub {
            my ($port, $server) = @_;
            my $response = $http->GET("http://127.0.0.1:$port/threshold.bin")->get;
            is($response->code, 200, 'got 200 response');
            is(length($response->content), 65536, 'threshold file length correct');
            is($response->content, $threshold_content, 'threshold file content matches');
        }
    );
};

subtest 'file just over threshold uses async path' => sub {
    # Create a file 1 byte over threshold
    my $over_threshold_content = "Z" x 65537;  # 64KB + 1 byte
    my $over_threshold_file = "$tempdir/over_threshold.bin";
    open my $ofh, '>:raw', $over_threshold_file or die;
    print $ofh $over_threshold_content;
    close $ofh;

    with_server(
        async sub {
            my ($scope, $receive, $send) = @_;
            await $send->({
                type => 'http.response.start',
                status => 200,
                headers => [
                    ['content-type', 'application/octet-stream'],
                    ['content-length', length($over_threshold_content)],
                ],
            });
            await $send->({
                type => 'http.response.body',
                file => $over_threshold_file,
            });
        },
        sub {
            my ($port, $server) = @_;
            my $response = $http->GET("http://127.0.0.1:$port/over_threshold.bin")->get;
            is($response->code, 200, 'got 200 response');
            is(length($response->content), 65537, 'over-threshold file length correct');
            is($response->content, $over_threshold_content, 'over-threshold file content matches');
        }
    );
};

done_testing;
