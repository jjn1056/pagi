#!/usr/bin/env perl

# =============================================================================
# Test: Directory listing security
#
# Verifies that PAGI::App::Directory:
# 1. Escapes HTML in filenames to prevent XSS
# 2. Blocks symlinks that escape the root directory
# =============================================================================

use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;
use File::Temp qw(tempdir);
use File::Spec;

require PAGI::App::Directory;

my $loop = IO::Async::Loop->new;

sub run_async {
    my ($code) = @_;
    my $future = $code->();
    $loop->await($future);
}

# =============================================================================
# Test: HTML escaping functions
# =============================================================================

subtest '_html_escape prevents XSS' => sub {
    # Test the escape function directly
    is(PAGI::App::Directory::_html_escape('<script>'), '&lt;script&gt;', 'escapes angle brackets');
    is(PAGI::App::Directory::_html_escape('"quoted"'), '&quot;quoted&quot;', 'escapes double quotes');
    is(PAGI::App::Directory::_html_escape("it's"), "it&#39;s", 'escapes single quotes');
    is(PAGI::App::Directory::_html_escape('a&b'), 'a&amp;b', 'escapes ampersand');
    is(PAGI::App::Directory::_html_escape('<script>alert("xss")</script>'),
       '&lt;script&gt;alert(&quot;xss&quot;)&lt;/script&gt;',
       'escapes full XSS payload');
    is(PAGI::App::Directory::_html_escape(undef), '', 'undef returns empty string');
    is(PAGI::App::Directory::_html_escape(''), '', 'empty string unchanged');
    is(PAGI::App::Directory::_html_escape('normal.txt'), 'normal.txt', 'normal filename unchanged');
};

subtest '_url_encode for href attributes' => sub {
    is(PAGI::App::Directory::_url_encode('normal.txt'), 'normal.txt', 'normal filename unchanged');
    is(PAGI::App::Directory::_url_encode('file with spaces.txt'), 'file%20with%20spaces.txt', 'spaces encoded');
    is(PAGI::App::Directory::_url_encode('file<script>.txt'), 'file%3Cscript%3E.txt', 'angle brackets encoded');
    is(PAGI::App::Directory::_url_encode(undef), '', 'undef returns empty string');
};

# =============================================================================
# Test: XSS prevention in directory listing
# =============================================================================

subtest 'XSS filenames are escaped in HTML output' => sub {
    # Create a temp directory with XSS-like filename
    my $tmpdir = tempdir(CLEANUP => 1);
    my $xss_name = '<script>alert(1)</script>.txt';

    # Create file with dangerous name (may fail on some filesystems)
    my $xss_path = File::Spec->catfile($tmpdir, $xss_name);
    my $created_xss = eval {
        open my $fh, '>', $xss_path or die $!;
        close $fh;
        1;
    };

    if ($created_xss) {
        my $dir = PAGI::App::Directory->new(root => $tmpdir);
        my $app = $dir->to_app;

        my @events;
        my $scope = {
            type => 'http',
            method => 'GET',
            path => '/',
            headers => [],
        };
        my $receive = async sub { { type => 'http.disconnect' } };
        my $send = async sub { push @events, $_[0] };

        run_async(async sub {
            await $app->($scope, $receive, $send);
        });

        is($events[0]{status}, 200, 'returns 200');

        my $body = $events[1]{body};
        unlike($body, qr/<script>alert/, 'XSS script tag is escaped in output');
        like($body, qr/&lt;script&gt;/, 'script tag appears as escaped HTML entities');
    } else {
        skip_all("Cannot create file with '<' in name on this filesystem");
    }
};

# =============================================================================
# Test: Symlink escape prevention
# =============================================================================

subtest 'symlink escape is blocked' => sub {
    plan skip_all => 'symlink not supported' unless eval { symlink("", ""); 1 } || $!{EPERM};

    # Create temp directories
    my $root = tempdir(CLEANUP => 1);
    my $outside = tempdir(CLEANUP => 1);

    # Create a file outside root
    my $secret_file = File::Spec->catfile($outside, 'secret.txt');
    open my $fh, '>', $secret_file or die "Cannot create $secret_file: $!";
    print $fh "SECRET DATA";
    close $fh;

    # Create symlink inside root pointing outside
    my $escape_link = File::Spec->catfile($root, 'escape');
    my $linked = eval { symlink($outside, $escape_link) };

    if ($linked) {
        my $dir = PAGI::App::Directory->new(root => $root);
        my $app = $dir->to_app;

        my @events;
        my $scope = {
            type => 'http',
            method => 'GET',
            path => '/escape',  # Try to access symlink
            headers => [],
        };
        my $receive = async sub { { type => 'http.disconnect' } };
        my $send = async sub { push @events, $_[0] };

        run_async(async sub {
            await $app->($scope, $receive, $send);
        });

        is($events[0]{status}, 403, 'symlink escape returns 403 Forbidden');
    } else {
        skip_all("Cannot create symlink: $!");
    }
};

subtest 'path traversal is blocked' => sub {
    my $root = tempdir(CLEANUP => 1);

    # Create a file in root
    open my $fh, '>', File::Spec->catfile($root, 'safe.txt') or die $!;
    close $fh;

    my $dir = PAGI::App::Directory->new(root => $root);
    my $app = $dir->to_app;

    my @events;
    my $scope = {
        type => 'http',
        method => 'GET',
        path => '/../../../etc/passwd',  # Path traversal attempt
        headers => [],
    };
    my $receive = async sub { { type => 'http.disconnect' } };
    my $send = async sub { push @events, $_[0] };

    run_async(async sub {
        await $app->($scope, $receive, $send);
    });

    is($events[0]{status}, 403, 'path traversal attempt returns 403');
};

subtest 'valid directory access works' => sub {
    my $root = tempdir(CLEANUP => 1);

    # Create a subdirectory
    my $subdir = File::Spec->catdir($root, 'subdir');
    mkdir $subdir or die "Cannot create $subdir: $!";

    # Create a file in subdirectory
    open my $fh, '>', File::Spec->catfile($subdir, 'file.txt') or die $!;
    close $fh;

    my $dir = PAGI::App::Directory->new(root => $root);
    my $app = $dir->to_app;

    my @events;
    my $scope = {
        type => 'http',
        method => 'GET',
        path => '/subdir',
        headers => [],
    };
    my $receive = async sub { { type => 'http.disconnect' } };
    my $send = async sub { push @events, $_[0] };

    run_async(async sub {
        await $app->($scope, $receive, $send);
    });

    is($events[0]{status}, 200, 'valid subdirectory returns 200');
    like($events[1]{body}, qr/file\.txt/, 'file.txt appears in listing');
};

done_testing;
