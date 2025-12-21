#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;

use lib 'lib';

use PAGI::App::SSE::Stream;
use PAGI::App::SSE::Pubsub;

my $loop = IO::Async::Loop->new;

sub run_async {
    my ($code) = @_;
    my $future = $code->();
    $loop->await($future);
}

# =============================================================================
# Test: PAGI::App::SSE::Stream
# =============================================================================

subtest 'App::SSE::Stream' => sub {

    subtest 'sends SSE headers' => sub {
        my $app = PAGI::App::SSE::Stream->new(
            generator => async sub  {
        my ($send_event, $scope) = @_;
                await $send_event->({ data => 'test' });
            },
        )->to_app;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'http', path => '/events' },
                async sub { { type => 'http.disconnect' } },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        is $sent[0]{type}, 'http.response.start', 'sends response start';
        is $sent[0]{status}, 200, 'status 200';

        my $content_type = (grep { $_->[0] eq 'content-type' } @{$sent[0]{headers}})[0];
        is $content_type->[1], 'text/event-stream', 'correct content-type';

        my $cache_control = (grep { $_->[0] eq 'cache-control' } @{$sent[0]{headers}})[0];
        is $cache_control->[1], 'no-cache', 'no-cache header';
    };

    subtest 'sends retry hint' => sub {
        my $app = PAGI::App::SSE::Stream->new(
            retry => 5000,
            generator => async sub  {
        my ($send_event, $scope) = @_;
                # Empty generator
            },
        )->to_app;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'http', path => '/events' },
                async sub { { type => 'http.disconnect' } },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        # Find retry event
        my $has_retry = grep { $_->{body} && $_->{body} =~ /retry: 5000/ } @sent;
        ok $has_retry, 'sends retry hint';
    };

    subtest 'sends events from generator' => sub {
        my $app = PAGI::App::SSE::Stream->new(
            generator => async sub  {
        my ($send_event, $scope) = @_;
                await $send_event->({ data => 'Hello' });
                await $send_event->({ event => 'custom', data => 'World' });
                await $send_event->({ id => '123', data => 'With ID' });
            },
        )->to_app;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'http', path => '/events' },
                async sub { { type => 'http.disconnect' } },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        # Collect body chunks
        my $body = join '', map { $_->{body} // '' } @sent;

        like $body, qr/data: Hello\n/, 'has first data';
        like $body, qr/event: custom\n/, 'has event type';
        like $body, qr/data: World\n/, 'has second data';
        like $body, qr/id: 123\n/, 'has event id';
    };

    subtest 'handles multiline data' => sub {
        my $app = PAGI::App::SSE::Stream->new(
            generator => async sub  {
        my ($send_event, $scope) = @_;
                await $send_event->({ data => "Line 1\nLine 2\nLine 3" });
            },
        )->to_app;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'http', path => '/events' },
                async sub { { type => 'http.disconnect' } },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        my $body = join '', map { $_->{body} // '' } @sent;
        like $body, qr/data: Line 1\ndata: Line 2\ndata: Line 3\n/, 'multiline data formatted correctly';
    };

    subtest 'calls on_connect callback' => sub {
        my $connected = 0;
        my $app = PAGI::App::SSE::Stream->new(
            on_connect => sub { $connected = 1 },
            generator => async sub  {
        my ($send_event, $scope) = @_; },
        )->to_app;

        run_async(async sub {
            await $app->(
                { type => 'http', path => '/events' },
                async sub { { type => 'http.disconnect' } },
                async sub  {
        my ($event) = @_; },
            );
        });

        ok $connected, 'on_connect called';
    };
};

# =============================================================================
# Test: PAGI::App::SSE::Pubsub
# =============================================================================

subtest 'App::SSE::Pubsub' => sub {

    subtest 'client_count starts at zero' => sub {
        my $count = PAGI::App::SSE::Pubsub->client_count;
        is $count, 0, 'starts with 0 clients';
    };

    subtest 'sends SSE headers' => sub {
        my $app = PAGI::App::SSE::Pubsub->new(channel => 'test_channel')->to_app;

        # We need to disconnect quickly
        my @events = ({ type => 'http.disconnect' });
        my $event_idx = 0;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'http', path => '/events', headers => [] },
                async sub { $events[$event_idx++] },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        is $sent[0]{status}, 200, 'status 200';
        my $content_type = (grep { $_->[0] eq 'content-type' } @{$sent[0]{headers}})[0];
        is $content_type->[1], 'text/event-stream', 'correct content-type';
    };

    subtest 'publish class method' => sub {
        # Just verify the method exists and doesn't crash
        my $can_publish = PAGI::App::SSE::Pubsub->can('publish');
        ok $can_publish, 'has publish method';
        PAGI::App::SSE::Pubsub->publish('nonexistent', { data => 'test' });
        pass 'publish to empty channel succeeds';
    };

    subtest 'list_channels class method' => sub {
        my $can_list = PAGI::App::SSE::Pubsub->can('list_channels');
        ok $can_list, 'has list_channels method';
        my @channels = PAGI::App::SSE::Pubsub->list_channels;
        ok ref(\@channels) eq 'ARRAY', 'returns list';
    };
};

done_testing;
