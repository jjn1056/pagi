#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;
use File::Spec;
use Cwd 'abs_path';

use lib 'lib';

use PAGI::Middleware::Static;

my $loop = IO::Async::Loop->new;

sub run_async {
    my ($code) = @_;
    my $future = $code->();
    $loop->await($future);
}

# Get absolute path to test files
my $test_root = abs_path('t/static_test_files');

# =============================================================================
# Test: Static middleware serves files with correct MIME types
# =============================================================================

subtest 'Static middleware serves HTML with correct MIME type' => sub {
    my $mw = PAGI::Middleware::Static->new(root => $test_root);

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type    => 'http.response.start',
            status  => 404,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'Not from static',
            more => 0,
        });
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/index.html', method => 'GET', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    is $sent[0]{status}, 200, 'status is 200';

    my $ct;
    for my $h (@{$sent[0]{headers}}) {
        if (lc($h->[0]) eq 'content-type') {
            $ct = $h->[1];
            last;
        }
    }
    is $ct, 'text/html', 'Content-Type is text/html';
    # Middleware now uses file => instead of body => for server to handle
    like $sent[1]{file}, qr/index\.html$/, 'file path points to index.html';
};

subtest 'Static middleware serves JavaScript with correct MIME type' => sub {
    my $mw = PAGI::Middleware::Static->new(root => $test_root);

    my $app = async sub { };
    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/app.js', method => 'GET', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    is $sent[0]{status}, 200, 'status is 200';

    my $ct;
    for my $h (@{$sent[0]{headers}}) {
        if (lc($h->[0]) eq 'content-type') {
            $ct = $h->[1];
            last;
        }
    }
    is $ct, 'application/javascript', 'Content-Type is application/javascript';
};

subtest 'Static middleware serves CSS with correct MIME type' => sub {
    my $mw = PAGI::Middleware::Static->new(root => $test_root);

    my $app = async sub { };
    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/style.css', method => 'GET', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    my $ct;
    for my $h (@{$sent[0]{headers}}) {
        if (lc($h->[0]) eq 'content-type') {
            $ct = $h->[1];
            last;
        }
    }
    is $ct, 'text/css', 'Content-Type is text/css';
};

# =============================================================================
# Test: Static middleware prevents path traversal attacks
# =============================================================================

subtest 'Static middleware prevents path traversal with ../' => sub {
    my $mw = PAGI::Middleware::Static->new(root => $test_root);

    my $app = async sub { };
    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/../../../etc/passwd', method => 'GET', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    is $sent[0]{status}, 403, 'status is 403 Forbidden';
};

subtest 'Static middleware prevents encoded path traversal' => sub {
    my $mw = PAGI::Middleware::Static->new(root => $test_root);

    my $app = async sub { };
    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/%2e%2e/%2e%2e/etc/passwd', method => 'GET', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    # Should be either 403 or 404 (not 200)
    ok $sent[0]{status} >= 400, 'status is 4xx (path traversal blocked)';
};

subtest 'Static middleware allows valid subdirectory access' => sub {
    my $mw = PAGI::Middleware::Static->new(root => $test_root);

    my $app = async sub { };
    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/subdir/file.txt', method => 'GET', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    is $sent[0]{status}, 200, 'status is 200 for valid subdirectory';
    # Middleware now uses file => instead of body => for server to handle
    like $sent[1]{file}, qr/subdir\/file\.txt$/, 'file path points to subdir/file.txt';
};

# =============================================================================
# Test: Static middleware supports ETag and 304 responses
# =============================================================================

subtest 'Static middleware returns ETag header' => sub {
    my $mw = PAGI::Middleware::Static->new(root => $test_root);

    my $app = async sub { };
    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/hello.txt', method => 'GET', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    my $etag;
    for my $h (@{$sent[0]{headers}}) {
        if (lc($h->[0]) eq 'etag') {
            $etag = $h->[1];
            last;
        }
    }

    ok $etag, 'ETag header present';
    like $etag, qr/^"[a-f0-9]+"$/, 'ETag format is quoted hex string';
};

subtest 'Static middleware returns 304 for matching ETag' => sub {
    my $mw = PAGI::Middleware::Static->new(root => $test_root);

    my $app = async sub { };
    my $wrapped = $mw->wrap($app);

    # First request to get ETag
    my @sent1;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/hello.txt', method => 'GET', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent1, $event },
        );
    });

    my $etag;
    for my $h (@{$sent1[0]{headers}}) {
        if (lc($h->[0]) eq 'etag') {
            $etag = $h->[1];
            last;
        }
    }

    # Second request with If-None-Match
    my @sent2;
    run_async(async sub {
        await $wrapped->(
            {
                type    => 'http',
                path    => '/hello.txt',
                method  => 'GET',
                headers => [['if-none-match', $etag]],
            },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent2, $event },
        );
    });

    is $sent2[0]{status}, 304, 'status is 304 Not Modified';
    is $sent2[1]{body}, '', 'body is empty for 304';
};

# =============================================================================
# Test: Static middleware supports Range requests
# =============================================================================

subtest 'Static middleware supports Range requests' => sub {
    my $mw = PAGI::Middleware::Static->new(root => $test_root);

    my $app = async sub { };
    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            {
                type    => 'http',
                path    => '/hello.txt',
                method  => 'GET',
                headers => [['range', 'bytes=0-4']],
            },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    is $sent[0]{status}, 206, 'status is 206 Partial Content';

    my ($content_range, $content_length);
    for my $h (@{$sent[0]{headers}}) {
        my $name = lc($h->[0]);
        $content_range = $h->[1] if $name eq 'content-range';
        $content_length = $h->[1] if $name eq 'content-length';
    }

    ok $content_range, 'Content-Range header present';
    like $content_range, qr/^bytes 0-4\//, 'Content-Range format is correct';
    is $content_length, 5, 'Content-Length is 5 bytes';
    # Middleware now uses file => with offset/length for server to handle range
    like $sent[1]{file}, qr/hello\.txt$/, 'file path points to hello.txt';
    is $sent[1]{offset}, 0, 'offset is 0';
    is $sent[1]{length}, 5, 'length is 5 bytes';
};

subtest 'Static middleware handles suffix range' => sub {
    my $mw = PAGI::Middleware::Static->new(root => $test_root);

    my $app = async sub { };
    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            {
                type    => 'http',
                path    => '/hello.txt',
                method  => 'GET',
                headers => [['range', 'bytes=-5']],  # Last 5 bytes
            },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    is $sent[0]{status}, 206, 'status is 206 for suffix range';
};

subtest 'Static middleware returns 416 for invalid range' => sub {
    my $mw = PAGI::Middleware::Static->new(root => $test_root);

    my $app = async sub { };
    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            {
                type    => 'http',
                path    => '/hello.txt',
                method  => 'GET',
                headers => [['range', 'bytes=1000-2000']],  # Beyond file size
            },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    is $sent[0]{status}, 416, 'status is 416 Range Not Satisfiable';
};

# =============================================================================
# Test: Other Static middleware features
# =============================================================================

subtest 'Static middleware returns 404 for missing files' => sub {
    my $mw = PAGI::Middleware::Static->new(root => $test_root);

    my $app = async sub { };
    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/nonexistent.txt', method => 'GET', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    is $sent[0]{status}, 404, 'status is 404 for missing file';
};

subtest 'Static middleware pass_through falls back to app' => sub {
    my $mw = PAGI::Middleware::Static->new(root => $test_root, pass_through => 1);

    my $app_called = 0;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $app_called = 1;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'From app',
            more => 0,
        });
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/nonexistent.txt', method => 'GET', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    ok $app_called, 'inner app was called';
    is $sent[1]{body}, 'From app', 'response from inner app';
};

subtest 'Static middleware path coderef can rewrite via return value' => sub {
    my $mw = PAGI::Middleware::Static->new(
        root => $test_root,
        path => sub {
            my ($path) = @_;
            return unless $path =~ m{^/static/};
            $path =~ s{^/static}{/};
            return $path;
        },
    );

    my $app = async sub { };
    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/static/hello.txt', method => 'GET', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    is $sent[0]{status}, 200, 'status is 200 for rewritten path';
    like $sent[1]{file}, qr/hello\.txt$/, 'file path points to hello.txt';
};

subtest 'Static middleware path coderef supports in-place rewrite without leading slash' => sub {
    my $mw = PAGI::Middleware::Static->new(
        root => $test_root,
        path => sub {
            $_[0] =~ s{^/static/}{};
            return 1;
        },
    );

    my $app = async sub { };
    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/static/hello.txt', method => 'GET', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    is $sent[0]{status}, 200, 'status is 200 after normalized rewrite';
    like $sent[1]{file}, qr/hello\.txt$/, 'file path points to hello.txt';
};

subtest 'Static middleware serves index file for directory' => sub {
    my $mw = PAGI::Middleware::Static->new(root => $test_root);

    my $app = async sub { };
    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/', method => 'GET', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    is $sent[0]{status}, 200, 'status is 200 for directory with index';
    # Middleware now uses file => instead of body => for server to handle
    like $sent[1]{file}, qr/index\.html$/, 'file path points to index.html';
};

subtest 'Static middleware handles HEAD requests' => sub {
    my $mw = PAGI::Middleware::Static->new(root => $test_root);

    my $app = async sub { };
    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/hello.txt', method => 'HEAD', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    is $sent[0]{status}, 200, 'status is 200 for HEAD';

    my $cl;
    for my $h (@{$sent[0]{headers}}) {
        if (lc($h->[0]) eq 'content-length') {
            $cl = $h->[1];
            last;
        }
    }

    ok $cl > 0, 'Content-Length header present';
    is $sent[1]{body}, '', 'body is empty for HEAD request';
};

subtest 'Static middleware skips non-GET/HEAD requests' => sub {
    my $mw = PAGI::Middleware::Static->new(root => $test_root);

    my $app_called = 0;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $app_called = 1;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [],
        });
        await $send->({
            type => 'http.response.body',
            body => 'POST handled',
            more => 0,
        });
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/hello.txt', method => 'POST', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    ok $app_called, 'inner app called for POST';
    is $sent[1]{body}, 'POST handled', 'POST passed through to app';
};

# =============================================================================
# Test: handle_ranges option
# =============================================================================

subtest 'Static middleware handle_ranges => 0 ignores Range header' => sub {
    my $mw = PAGI::Middleware::Static->new(root => $test_root, handle_ranges => 0);

    my $app = async sub { };
    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            {
                type    => 'http',
                path    => '/hello.txt',
                method  => 'GET',
                headers => [['range', 'bytes=0-4']],
            },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    is $sent[0]{status}, 200, 'status is 200 (not 206) when handle_ranges => 0';

    # Verify no Content-Range header
    my $content_range;
    for my $h (@{$sent[0]{headers}}) {
        $content_range = $h->[1] if lc($h->[0]) eq 'content-range';
    }
    ok !$content_range, 'No Content-Range header when handle_ranges => 0';

    # Verify full file is returned (no offset/length)
    ok !defined $sent[1]{offset}, 'No offset in file response';
    ok !defined $sent[1]{length}, 'No length in file response';
    like $sent[1]{file}, qr/hello\.txt$/, 'Full file path returned';
};

subtest 'Static middleware handle_ranges => 1 (default) honors Range header' => sub {
    my $mw = PAGI::Middleware::Static->new(root => $test_root, handle_ranges => 1);

    my $app = async sub { };
    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            {
                type    => 'http',
                path    => '/hello.txt',
                method  => 'GET',
                headers => [['range', 'bytes=0-4']],
            },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    is $sent[0]{status}, 206, 'status is 206 when handle_ranges => 1';

    my $content_range;
    for my $h (@{$sent[0]{headers}}) {
        $content_range = $h->[1] if lc($h->[0]) eq 'content-range';
    }
    ok $content_range, 'Content-Range header present';
    like $content_range, qr/^bytes 0-4\//, 'Content-Range format is correct';

    # Verify partial file with offset/length
    is $sent[1]{offset}, 0, 'offset is 0';
    is $sent[1]{length}, 5, 'length is 5 bytes';
};

subtest 'Static middleware default handle_ranges honors Range header' => sub {
    # No handle_ranges specified - should default to 1
    my $mw = PAGI::Middleware::Static->new(root => $test_root);

    my $app = async sub { };
    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            {
                type    => 'http',
                path    => '/hello.txt',
                method  => 'GET',
                headers => [['range', 'bytes=0-4']],
            },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    is $sent[0]{status}, 206, 'default behavior honors Range header (206)';
};

# =============================================================================
# Test: Double URL-decoding prevention
# =============================================================================

subtest 'Static middleware does not double URL-decode paths' => sub {
    my $mw = PAGI::Middleware::Static->new(root => $test_root);

    my $app = async sub { };
    my $wrapped = $mw->wrap($app);

    # Simulate a path that the server has already decoded from %252e%252e to %2e%2e.
    # The middleware must NOT decode this again into ".." which would enable traversal.
    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/%2e%2e/etc/passwd', method => 'GET', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    # With no double-decode, %2e%2e stays literal - file won't exist, so 404 (not 403 from traversal)
    ok $sent[0]{status} >= 400, 'double-encoded path traversal is blocked (not 200)';
};

done_testing;
