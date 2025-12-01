#!/usr/bin/env perl

use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;

use lib 'lib';

use PAGI::Middleware::ErrorHandler;

my $loop = IO::Async::Loop->new;

sub run_async {
    my ($code) = @_;
    my $future = $code->();
    $loop->await($future);
}

# =============================================================================
# Test: ErrorHandler middleware catches exceptions
# =============================================================================

subtest 'ErrorHandler catches exceptions and returns 500' => sub {
    my $mw = PAGI::Middleware::ErrorHandler->new;

    my $app = async sub ($scope, $receive, $send) {
        die "Something went wrong!";
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

    is scalar(@sent), 2, 'two events sent (start + body)';
    is $sent[0]{type}, 'http.response.start', 'first event is response start';
    is $sent[0]{status}, 500, 'status is 500';

    # Check content-type header
    my $ct;
    for my $h (@{$sent[0]{headers}}) {
        if (lc($h->[0]) eq 'content-type') {
            $ct = $h->[1];
            last;
        }
    }
    like $ct, qr/text\/html/, 'content-type is text/html';
    like $sent[1]{body}, qr/Error 500/, 'body contains error status';
};

subtest 'ErrorHandler shows stack trace in development mode' => sub {
    my $mw = PAGI::Middleware::ErrorHandler->new(development => 1);

    my $app = async sub ($scope, $receive, $send) {
        die "Detailed error message";
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

    like $sent[1]{body}, qr/Detailed error message/, 'error message shown in dev mode';
    like $sent[1]{body}, qr/Stack Trace/, 'stack trace section present';
};

subtest 'ErrorHandler hides details in production mode' => sub {
    my $mw = PAGI::Middleware::ErrorHandler->new(development => 0);

    my $app = async sub ($scope, $receive, $send) {
        die "Secret internal error details";
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

    unlike $sent[1]{body}, qr/Secret internal error details/, 'error details hidden in production';
    like $sent[1]{body}, qr/Internal Server Error/, 'generic message shown';
};

subtest 'ErrorHandler calls on_error callback' => sub {
    my @errors;
    my $mw = PAGI::Middleware::ErrorHandler->new(
        on_error => sub ($error) { push @errors, $error },
    );

    my $app = async sub ($scope, $receive, $send) {
        die "Test error for callback";
    };

    my $wrapped = $mw->wrap($app);

    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/' },
            async sub { { type => 'http.disconnect' } },
            async sub ($event) { },
        );
    });

    is scalar(@errors), 1, 'on_error called once';
    like $errors[0], qr/Test error for callback/, 'error passed to callback';
};

subtest 'ErrorHandler supports JSON content type' => sub {
    my $mw = PAGI::Middleware::ErrorHandler->new(
        content_type => 'application/json',
        development  => 1,
    );

    my $app = async sub ($scope, $receive, $send) {
        die "JSON error";
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

    my $ct;
    for my $h (@{$sent[0]{headers}}) {
        if (lc($h->[0]) eq 'content-type') {
            $ct = $h->[1];
            last;
        }
    }
    is $ct, 'application/json', 'content-type is JSON';

    require JSON::PP;
    my $data = JSON::PP::decode_json($sent[1]{body});
    is $data->{status}, 500, 'JSON contains status';
    like $data->{error}, qr/JSON error/, 'JSON contains error';
    ok exists $data->{stack}, 'JSON contains stack in dev mode';
};

subtest 'ErrorHandler supports plain text content type' => sub {
    my $mw = PAGI::Middleware::ErrorHandler->new(
        content_type => 'text/plain',
    );

    my $app = async sub ($scope, $receive, $send) {
        die "Plain text error";
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

    my $ct;
    for my $h (@{$sent[0]{headers}}) {
        if (lc($h->[0]) eq 'content-type') {
            $ct = $h->[1];
            last;
        }
    }
    like $ct, qr/text\/plain/, 'content-type is plain text';
    like $sent[1]{body}, qr/Error 500/, 'plain text body contains error';
};

subtest 'ErrorHandler respects exception status_code method' => sub {
    package TestException {
        sub new { bless { status => $_[1] }, $_[0] }
        sub status_code { $_[0]->{status} }
    }

    my $mw = PAGI::Middleware::ErrorHandler->new;

    my $app = async sub ($scope, $receive, $send) {
        die TestException->new(404);
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

    is $sent[0]{status}, 404, 'status from exception status_code method';
    like $sent[1]{body}, qr/Error 404/, 'body reflects status';
};

subtest 'ErrorHandler passes through successful responses' => sub {
    my $mw = PAGI::Middleware::ErrorHandler->new;

    my $app = async sub ($scope, $receive, $send) {
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'Success!',
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
    is $sent[0]{status}, 200, 'status is 200';
    is $sent[1]{body}, 'Success!', 'body is correct';
};

subtest 'ErrorHandler skips non-HTTP requests' => sub {
    my $mw = PAGI::Middleware::ErrorHandler->new;

    my $app_called = 0;
    my $app = async sub ($scope, $receive, $send) {
        $app_called = 1;
        die "WebSocket error";
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    my $future = $wrapped->(
        { type => 'websocket', path => '/' },
        async sub { { type => 'websocket.disconnect' } },
        async sub ($event) { push @sent, $event },
    );

    # The future should fail (not be caught by middleware)
    $loop->await($future->else(sub { Future->done }));

    ok $app_called, 'app was called';
    ok $future->is_failed, 'future failed (error propagated)';
    like $future->failure, qr/WebSocket error/, 'original error preserved';
};

subtest 'ErrorHandler escapes HTML in error messages' => sub {
    my $mw = PAGI::Middleware::ErrorHandler->new(development => 1);

    my $app = async sub ($scope, $receive, $send) {
        die "<script>alert('xss')</script>";
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

    unlike $sent[1]{body}, qr/<script>/, 'script tag escaped';
    like $sent[1]{body}, qr/&lt;script&gt;/, 'HTML entities used';
};

done_testing;
