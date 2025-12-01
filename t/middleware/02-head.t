#!/usr/bin/env perl

use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;

use lib 'lib';

use PAGI::Middleware::Head;

my $loop = IO::Async::Loop->new;

sub run_async {
    my ($code) = @_;
    my $future = $code->();
    $loop->await($future);
}

# =============================================================================
# Test: Head middleware suppresses response body
# =============================================================================

subtest 'Head middleware suppresses body for HEAD requests' => sub {
    my $mw = PAGI::Middleware::Head->new;

    my $received_method;
    my $app = async sub ($scope, $receive, $send) {
        $received_method = $scope->{method};
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [
                ['content-type', 'text/plain'],
                ['content-length', '13'],
            ],
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
            { type => 'http', path => '/', method => 'HEAD' },
            async sub { { type => 'http.disconnect' } },
            async sub ($event) { push @sent, $event },
        );
    });

    is $received_method, 'GET', 'inner app receives GET instead of HEAD';
    is scalar(@sent), 2, 'two events sent (start + body)';
    is $sent[0]{type}, 'http.response.start', 'first event is response start';

    # Headers should be preserved, including Content-Length
    my $found_length;
    for my $h (@{$sent[0]{headers}}) {
        if (lc($h->[0]) eq 'content-length') {
            $found_length = $h->[1];
            last;
        }
    }
    is $found_length, '13', 'Content-Length preserved';

    # Body should be empty
    is $sent[1]{type}, 'http.response.body', 'second event is body';
    is $sent[1]{body}, '', 'body is empty';
    is $sent[1]{more}, 0, 'body is complete (more => 0)';
};

subtest 'Head middleware passes through GET requests' => sub {
    my $mw = PAGI::Middleware::Head->new;

    my $received_method;
    my $app = async sub ($scope, $receive, $send) {
        $received_method = $scope->{method};
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
            { type => 'http', path => '/', method => 'GET' },
            async sub { { type => 'http.disconnect' } },
            async sub ($event) { push @sent, $event },
        );
    });

    is $received_method, 'GET', 'GET request passed through unchanged';
    is $sent[1]{body}, 'Hello', 'body is preserved for GET';
};

subtest 'Head middleware handles streaming responses' => sub {
    my $mw = PAGI::Middleware::Head->new;

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
            more => 1,
        });
        await $send->({
            type => 'http.response.body',
            body => 'Chunk 3',
            more => 0,
        });
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/', method => 'HEAD' },
            async sub { { type => 'http.disconnect' } },
            async sub ($event) { push @sent, $event },
        );
    });

    # Should have start + one final empty body
    is scalar(@sent), 2, 'only start and final body sent';
    is $sent[0]{type}, 'http.response.start', 'first event is start';
    is $sent[1]{type}, 'http.response.body', 'second event is body';
    is $sent[1]{body}, '', 'body is empty';
    is $sent[1]{more}, 0, 'response is complete';
};

subtest 'Head middleware suppresses trailers' => sub {
    my $mw = PAGI::Middleware::Head->new;

    my $app = async sub ($scope, $receive, $send) {
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [
                ['content-type', 'text/plain'],
                ['trailer', 'x-checksum'],
            ],
            trailers => 1,
        });
        await $send->({
            type => 'http.response.body',
            body => 'Hello',
            more => 0,
        });
        await $send->({
            type    => 'http.response.trailers',
            headers => [['x-checksum', 'abc123']],
        });
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/', method => 'HEAD' },
            async sub { { type => 'http.disconnect' } },
            async sub ($event) { push @sent, $event },
        );
    });

    # Trailers should be suppressed
    my @trailer_events = grep { $_->{type} eq 'http.response.trailers' } @sent;
    is scalar(@trailer_events), 0, 'trailers suppressed for HEAD';
};

subtest 'Head middleware skips non-HTTP requests' => sub {
    my $mw = PAGI::Middleware::Head->new;

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

subtest 'Head middleware preserves other HTTP methods' => sub {
    my $mw = PAGI::Middleware::Head->new;

    for my $method (qw(POST PUT DELETE PATCH OPTIONS)) {
        my $received_method;
        my $app = async sub ($scope, $receive, $send) {
            $received_method = $scope->{method};
            await $send->({
                type    => 'http.response.start',
                status  => 200,
                headers => [],
            });
            await $send->({
                type => 'http.response.body',
                body => 'Response',
                more => 0,
            });
        };

        my $wrapped = $mw->wrap($app);

        my @sent;
        run_async(async sub {
            await $wrapped->(
                { type => 'http', path => '/', method => $method },
                async sub { { type => 'http.disconnect' } },
                async sub ($event) { push @sent, $event },
            );
        });

        is $received_method, $method, "$method request passed through unchanged";
        is $sent[1]{body}, 'Response', "body preserved for $method";
    }
};

done_testing;
