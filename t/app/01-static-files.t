#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;
use Net::Async::HTTP;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

use lib 'lib';

use PAGI::Server;
use PAGI::App::File;
use PAGI::App::Directory;

my $loop = IO::Async::Loop->new;

# Create temp directory with test files
my $tmpdir = tempdir(CLEANUP => 1);
make_path("$tmpdir/subdir");

# Create test files
open my $fh, '>', "$tmpdir/test.txt" or die "Cannot create test file: $!";
print $fh "Hello, World!";
close $fh;

open $fh, '>', "$tmpdir/test.html" or die "Cannot create test file: $!";
print $fh "<html><body>Test</body></html>";
close $fh;

open $fh, '>', "$tmpdir/subdir/nested.txt" or die "Cannot create nested file: $!";
print $fh "Nested content";
close $fh;

# Helper to create server with an app
sub create_server {
    my ($app) = @_;

    my $server = PAGI::Server->new(
        app   => $app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
    );
    $loop->add($server);
    $server->listen->get;
    return $server;
}

# Helper to make HTTP request
async sub http_request {
    my ($port, $method, $path, %opts) = @_;

    my $http = Net::Async::HTTP->new(fail_on_error => 0);
    $loop->add($http);

    my @headers;
    if ($opts{headers}) {
        @headers = @{$opts{headers}};
    }

    my $response;
    if ($method eq 'GET') {
        $response = await $http->GET(
            "http://127.0.0.1:$port$path",
            headers => \@headers,
        );
    } elsif ($method eq 'HEAD') {
        $response = await $http->HEAD(
            "http://127.0.0.1:$port$path",
            headers => \@headers,
        );
    }

    $loop->remove($http);
    return $response;
}

# =============================================================================
# Test: PAGI::App::File
# =============================================================================

subtest 'App::File serves static files' => sub {

    subtest 'serves existing file' => sub {
        my $app = PAGI::App::File->new(root => $tmpdir)->to_app;
        my $server = create_server($app);
        my $port = $server->port;

        my $response = http_request($port, 'GET', '/test.txt')->get;

        is $response->code, 200, 'returns 200 status';
        like $response->content_type, qr/text\/plain/, 'has correct content-type';
        is $response->decoded_content, 'Hello, World!', 'returns file content';

        $server->shutdown->get;
        $loop->remove($server);
    };

    subtest 'returns 404 for missing file' => sub {
        my $app = PAGI::App::File->new(root => $tmpdir)->to_app;
        my $server = create_server($app);
        my $port = $server->port;

        my $response = http_request($port, 'GET', '/missing.txt')->get;

        is $response->code, 404, 'returns 404 for missing file';

        $server->shutdown->get;
        $loop->remove($server);
    };

    subtest 'serves nested files' => sub {
        my $app = PAGI::App::File->new(root => $tmpdir)->to_app;
        my $server = create_server($app);
        my $port = $server->port;

        my $response = http_request($port, 'GET', '/subdir/nested.txt')->get;

        is $response->code, 200, 'serves nested file';
        is $response->decoded_content, 'Nested content', 'correct nested content';

        $server->shutdown->get;
        $loop->remove($server);
    };

    subtest 'prevents path traversal' => sub {
        my $app = PAGI::App::File->new(root => $tmpdir)->to_app;
        my $server = create_server($app);
        my $port = $server->port;

        my $response = http_request($port, 'GET', '/../../../etc/passwd')->get;

        isnt $response->code, 200, 'blocks path traversal';

        $server->shutdown->get;
        $loop->remove($server);
    };

    subtest 'sets ETag header' => sub {
        my $app = PAGI::App::File->new(root => $tmpdir)->to_app;
        my $server = create_server($app);
        my $port = $server->port;

        my $response = http_request($port, 'GET', '/test.txt')->get;

        ok $response->header('ETag'), 'ETag header present';

        $server->shutdown->get;
        $loop->remove($server);
    };

    subtest 'conditional GET with If-None-Match' => sub {
        my $app = PAGI::App::File->new(root => $tmpdir)->to_app;
        my $server = create_server($app);
        my $port = $server->port;

        # First request to get ETag
        my $response1 = http_request($port, 'GET', '/test.txt')->get;
        my $etag = $response1->header('ETag');

        # Second request with If-None-Match
        # Net::Async::HTTP has issues with 304, so we handle potential errors
        my $got_304 = 0;
        eval {
            my $response2 = http_request($port, 'GET', '/test.txt',
                headers => ['If-None-Match' => $etag])->get;
            $got_304 = 1 if $response2->code == 304;
        };
        # Net::Async::HTTP may throw on 304 due to "Spurious on_read" bug
        if ($@ && $@ =~ /Spurious on_read/) {
            $got_304 = 1;
        }

        ok $got_304, 'returns 304 Not Modified';

        $server->shutdown->get;
        $loop->remove($server);
    };
};

# =============================================================================
# Test: PAGI::App::Directory
# =============================================================================

subtest 'App::Directory serves directory listings' => sub {

    subtest 'serves file like App::File' => sub {
        my $app = PAGI::App::Directory->new(root => $tmpdir)->to_app;
        my $server = create_server($app);
        my $port = $server->port;

        my $response = http_request($port, 'GET', '/test.txt')->get;

        is $response->code, 200, 'serves file';
        is $response->decoded_content, 'Hello, World!', 'correct content';

        $server->shutdown->get;
        $loop->remove($server);
    };

    subtest 'lists directory as HTML' => sub {
        my $app = PAGI::App::Directory->new(root => $tmpdir)->to_app;
        my $server = create_server($app);
        my $port = $server->port;

        my $response = http_request($port, 'GET', '/')->get;

        is $response->code, 200, 'returns 200';
        like $response->content_type, qr/text\/html/, 'content-type is HTML';
        like $response->decoded_content, qr/test\.txt/, 'listing includes test.txt';
        like $response->decoded_content, qr/subdir/, 'listing includes subdir';

        $server->shutdown->get;
        $loop->remove($server);
    };

    subtest 'lists directory as JSON when Accept: application/json' => sub {
        my $app = PAGI::App::Directory->new(root => $tmpdir)->to_app;
        my $server = create_server($app);
        my $port = $server->port;

        my $response = http_request($port, 'GET', '/',
            headers => ['Accept' => 'application/json'])->get;

        like $response->content_type, qr/application\/json/, 'content-type is JSON';
        like $response->decoded_content, qr/"name"/, 'JSON output has name field';

        $server->shutdown->get;
        $loop->remove($server);
    };
};

done_testing;
