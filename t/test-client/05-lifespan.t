#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;

use lib 'lib';
use PAGI::Test::Client;
use PAGI::Lifespan;

my $startup_called = 0;
my $shutdown_called = 0;

my $lifespan_app = async sub {
    my ($scope, $receive, $send) = @_;

    if ($scope->{type} eq 'lifespan') {
        my $event = await $receive->();

        if ($event->{type} eq 'lifespan.startup') {
            $startup_called = 1;
            $scope->{state}{db} = 'connected';
            await $send->({ type => 'lifespan.startup.complete' });
        }

        $event = await $receive->();
        if ($event->{type} eq 'lifespan.shutdown') {
            $shutdown_called = 1;
            await $send->({ type => 'lifespan.shutdown.complete' });
        }
        return;
    }

    # HTTP
    await $send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [['content-type', 'text/plain']],
    });

    await $send->({
        type => 'http.response.body',
        body => "DB: " . ($scope->{state}{db} // 'none'),
        more => 0,
    });
};

subtest 'lifespan disabled by default' => sub {
    $startup_called = 0;
    my $client = PAGI::Test::Client->new(app => $lifespan_app);
    my $res = $client->get('/');

    ok !$startup_called, 'startup not called when lifespan disabled';
    is $res->text, 'DB: none', 'no state without lifespan';
};

subtest 'lifespan explicit start/stop' => sub {
    $startup_called = 0;
    $shutdown_called = 0;

    my $client = PAGI::Test::Client->new(app => $lifespan_app, lifespan => 1);
    $client->start;

    ok $startup_called, 'startup called';

    my $res = $client->get('/');
    is $res->text, 'DB: connected', 'state available';

    $client->stop;
    ok $shutdown_called, 'shutdown called';
};

subtest 'lifespan run() helper' => sub {
    $startup_called = 0;
    $shutdown_called = 0;

    PAGI::Test::Client->run($lifespan_app, sub {
        my ($client) = @_;
        ok $startup_called, 'startup called in run()';
        my $res = $client->get('/');
        is $res->text, 'DB: connected', 'state in run()';
    });

    ok $shutdown_called, 'shutdown called after run()';
};

subtest 'lifespan manager aggregates hooks' => sub {
    my @events;

    my $lifespan = PAGI::Lifespan->new;
    $lifespan->on_startup(async sub {
        my ($state) = @_;
        push @events, 'outer_start';
        $state->{outer} = 1;
    });
    $lifespan->on_shutdown(async sub {
        my ($state) = @_;
        push @events, 'outer_stop';
    });
    $lifespan->on_startup(async sub {
        my ($state) = @_;
        push @events, 'inner_start';
        $state->{inner} = 1;
    });
    $lifespan->on_shutdown(async sub {
        my ($state) = @_;
        push @events, 'inner_stop';
    });

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} eq 'lifespan') {
            return await $lifespan->handle($scope, $receive, $send);
        }
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => "ok",
            more => 0,
        });
    };

    my $client = PAGI::Test::Client->new(app => $app, lifespan => 1);
    $client->start;
    $client->get('/');
    $client->stop;

    is \@events, ['outer_start', 'inner_start', 'inner_stop', 'outer_stop'],
        'startup runs outer->inner, shutdown runs inner->outer';

    ok $client->state->{outer}, 'outer startup wrote to shared state';
    ok $client->state->{inner}, 'inner startup wrote to shared state';
};

done_testing;
