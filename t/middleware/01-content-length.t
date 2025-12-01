#!/usr/bin/env perl

use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;

use lib 'lib';

use PAGI::Middleware::ContentLength;

my $loop = IO::Async::Loop->new;

sub run_async {
    my ($code) = @_;
    my $future = $code->();
    $loop->await($future);
}

# =============================================================================
# Test: ContentLength middleware adds accurate Content-Length header
# =============================================================================

subtest 'ContentLength adds header for buffered response' => sub {
    my $mw = PAGI::Middleware::ContentLength->new;

    # App that doesn't set Content-Length
    my $app = async sub ($scope, $receive, $send) {
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'Hello, World!',
            more => 0,
        });
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/' },
            async sub { { type => 'http.disconnect' } },
            async sub ($event) { push @sent, $event },
        );
    });

    is scalar(@sent), 2, 'two events sent';
    is $sent[0]{type}, 'http.response.start', 'first event is response start';

    # Check Content-Length header was added
    my $found_length;
    for my $h (@{$sent[0]{headers}}) {
        if (lc($h->[0]) eq 'content-length') {
            $found_length = $h->[1];
            last;
        }
    }

    is $found_length, 13, 'Content-Length is 13 (length of "Hello, World!")';
    is $sent[1]{body}, 'Hello, World!', 'body is correct';
};

subtest 'ContentLength preserves existing Content-Length' => sub {
    my $mw = PAGI::Middleware::ContentLength->new;

    # App that already sets Content-Length
    my $app = async sub ($scope, $receive, $send) {
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [
                ['content-type', 'text/plain'],
                ['content-length', '5'],
            ],
        });
        await $send->({
            type => 'http.response.body',
            body => 'Hello',
            more => 0,
        });
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/' },
            async sub { { type => 'http.disconnect' } },
            async sub ($event) { push @sent, $event },
        );
    });

    # Count Content-Length headers
    my @lengths = grep { lc($_->[0]) eq 'content-length' } @{$sent[0]{headers}};
    is scalar(@lengths), 1, 'only one Content-Length header';
    is $lengths[0][1], '5', 'original Content-Length preserved';
};

subtest 'ContentLength passes through streaming responses' => sub {
    my $mw = PAGI::Middleware::ContentLength->new;

    # App that streams response (more => 1)
    my $app = async sub ($scope, $receive, $send) {
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'Chunk 1',
            more => 1,
        });
        await $send->({
            type => 'http.response.body',
            body => 'Chunk 2',
            more => 0,
        });
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/' },
            async sub { { type => 'http.disconnect' } },
            async sub ($event) { push @sent, $event },
        );
    });

    is scalar(@sent), 3, 'three events sent (start + 2 body)';

    # No Content-Length should be added for streaming
    my @lengths = grep { lc($_->[0]) eq 'content-length' } @{$sent[0]{headers}};
    is scalar(@lengths), 0, 'no Content-Length for streaming response';
};

subtest 'ContentLength skips non-HTTP requests' => sub {
    my $mw = PAGI::Middleware::ContentLength->new;

    my $app_called = 0;
    my $app = async sub ($scope, $receive, $send) {
        $app_called = 1;
        await $send->({
            type    => 'websocket.accept',
            headers => [],
        });
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'websocket', path => '/' },
            async sub { { type => 'websocket.disconnect' } },
            async sub ($event) { push @sent, $event },
        );
    });

    ok $app_called, 'app was called';
    is $sent[0]{type}, 'websocket.accept', 'websocket event passed through';
};

subtest 'ContentLength handles empty body' => sub {
    my $mw = PAGI::Middleware::ContentLength->new;

    my $app = async sub ($scope, $receive, $send) {
        await $send->({
            type    => 'http.response.start',
            status  => 204,
            headers => [],
        });
        await $send->({
            type => 'http.response.body',
            body => '',
            more => 0,
        });
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/' },
            async sub { { type => 'http.disconnect' } },
            async sub ($event) { push @sent, $event },
        );
    });

    my $found_length;
    for my $h (@{$sent[0]{headers}}) {
        if (lc($h->[0]) eq 'content-length') {
            $found_length = $h->[1];
            last;
        }
    }

    is $found_length, 0, 'Content-Length is 0 for empty body';
};

subtest 'ContentLength handles binary body correctly' => sub {
    my $mw = PAGI::Middleware::ContentLength->new;

    my $binary = "\x00\x01\x02\x03\x04";
    my $app = async sub ($scope, $receive, $send) {
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'application/octet-stream']],
        });
        await $send->({
            type => 'http.response.body',
            body => $binary,
            more => 0,
        });
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/' },
            async sub { { type => 'http.disconnect' } },
            async sub ($event) { push @sent, $event },
        );
    });

    my $found_length;
    for my $h (@{$sent[0]{headers}}) {
        if (lc($h->[0]) eq 'content-length') {
            $found_length = $h->[1];
            last;
        }
    }

    is $found_length, 5, 'Content-Length is 5 for binary body';
};

subtest 'ContentLength auto_chunked option' => sub {
    my $mw = PAGI::Middleware::ContentLength->new(auto_chunked => 1);

    my $app = async sub ($scope, $receive, $send) {
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'Hello',
            more => 0,
        });
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/' },
            async sub { { type => 'http.disconnect' } },
            async sub ($event) { push @sent, $event },
        );
    });

    # No Content-Length should be added with auto_chunked
    my @lengths = grep { lc($_->[0]) eq 'content-length' } @{$sent[0]{headers}};
    is scalar(@lengths), 0, 'no Content-Length with auto_chunked';
};

done_testing;
