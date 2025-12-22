#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;
use IO::Async::Loop;

use lib 'lib';
use PAGI::SSE;

subtest 'keepalive sends periodic comments' => sub {
    my $loop = IO::Async::Loop->new;
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };

    my $sse = PAGI::SSE->new({ type => 'sse' }, sub {}, $send);
    $sse->set_loop($loop);
    $sse->start->get;

    # Enable keepalive with 0.1 second interval for testing
    $sse->keepalive(0.1);

    # Wait for a couple pings
    $loop->delay_future(after => 0.25)->get;

    # Stop keepalive
    $sse->keepalive(0);

    # Should have sent at least 2 keepalive comments
    my @keepalives = grep { ($_->{data} // '') =~ /^:/ } @sent;
    ok(@keepalives >= 2, 'at least 2 keepalive pings sent');
};

subtest 'keepalive with custom comment' => sub {
    my $loop = IO::Async::Loop->new;
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };

    my $sse = PAGI::SSE->new({ type => 'sse' }, sub {}, $send);
    $sse->set_loop($loop);
    $sse->start->get;

    $sse->keepalive(0.1, ':ping');

    $loop->delay_future(after => 0.15)->get;

    $sse->keepalive(0);

    my @pings = grep { ($_->{data} // '') eq ':ping' } @sent;
    ok(@pings >= 1, 'custom keepalive comment sent');
};

subtest 'keepalive(0) disables timer' => sub {
    my $loop = IO::Async::Loop->new;
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };

    my $sse = PAGI::SSE->new({ type => 'sse' }, sub {}, $send);
    $sse->set_loop($loop);
    $sse->start->get;

    $sse->keepalive(0.1);
    $sse->keepalive(0);  # Disable immediately

    my $before_count = scalar @sent;
    $loop->delay_future(after => 0.2)->get;
    my $after_count = scalar @sent;

    is($after_count, $before_count, 'no keepalive sent after disable');
};

done_testing;
