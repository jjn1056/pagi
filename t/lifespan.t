use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;

my $loaded = eval { require PAGI::Lifespan; 1 };
ok($loaded, 'PAGI::Lifespan loads') or diag $@;

subtest 'basic class structure' => sub {
    ok(PAGI::Lifespan->can('new'), 'has new');
    ok(PAGI::Lifespan->can('wrap'), 'has wrap');
    ok(PAGI::Lifespan->can('to_app'), 'has to_app');
    ok(PAGI::Lifespan->can('state'), 'has state');
};

subtest 'wrap returns coderef' => sub {
    my $inner_app = async sub { };
    my $app = PAGI::Lifespan->wrap($inner_app);
    is(ref($app), 'CODE', 'wrap returns coderef');
};

subtest 'startup and shutdown callbacks' => sub {
    my $startup_called = 0;
    my $shutdown_called = 0;
    my $state_in_startup;

    my $inner_app = async sub { };

    my $lifespan = PAGI::Lifespan->new(
        app      => $inner_app,
        startup  => async sub {
            my ($state) = @_;
            $startup_called = 1;
            $state->{db} = 'connected';
            $state_in_startup = $state;
        },
        shutdown => async sub {
            my ($state) = @_;
            $shutdown_called = 1;
        },
    );

    my $app = $lifespan->to_app;

    (async sub {
        my @sent;
        my $send = sub { push @sent, $_[0]; Future->done };

        my $msg_index = 0;
        my @messages = (
            { type => 'lifespan.startup' },
            { type => 'lifespan.shutdown' },
        );
        my $receive = sub { Future->done($messages[$msg_index++]) };

        await $app->({ type => 'lifespan' }, $receive, $send);

        ok($startup_called, 'startup callback was called');
        ok($shutdown_called, 'shutdown callback was called');
        is($sent[0]{type}, 'lifespan.startup.complete', 'startup complete sent');
        is($sent[1]{type}, 'lifespan.shutdown.complete', 'shutdown complete sent');
        is($state_in_startup->{db}, 'connected', 'state was passed to startup');
    })->()->get;
};

subtest 'state injected into scope for requests' => sub {
    my $scope_state;

    my $inner_app = async sub {
        my ($scope, $receive, $send) = @_;
        $scope_state = $scope->{state};
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'ok' });
    };

    my $lifespan = PAGI::Lifespan->new(
        app     => $inner_app,
        startup => async sub {
            my ($state) = @_;
            $state->{db} = 'test-connection';
        },
    );

    my $app = $lifespan->to_app;

    (async sub {
        # First run lifespan startup
        my $msg_index = 0;
        my @lifespan_messages = (
            { type => 'lifespan.startup' },
            { type => 'lifespan.shutdown' },
        );

        await $app->(
            { type => 'lifespan' },
            sub { Future->done($lifespan_messages[$msg_index++]) },
            sub { Future->done }
        );

        # Now make an HTTP request
        my @sent;
        await $app->(
            { type => 'http', method => 'GET', path => '/', headers => [] },
            sub { Future->done({ type => 'http.request', body => '' }) },
            sub { push @sent, $_[0]; Future->done }
        );

        is($scope_state->{db}, 'test-connection', 'state injected into scope');
    })->()->get;
};

subtest 'startup failure sends failed message' => sub {
    my $inner_app = async sub { };

    my $lifespan = PAGI::Lifespan->new(
        app     => $inner_app,
        startup => async sub { die "Connection failed"; },
    );

    my $app = $lifespan->to_app;

    (async sub {
        my @sent;
        await $app->(
            { type => 'lifespan' },
            sub { Future->done({ type => 'lifespan.startup' }) },
            sub { push @sent, $_[0]; Future->done }
        );

        is($sent[0]{type}, 'lifespan.startup.failed', 'startup failed sent');
        like($sent[0]{message}, qr/Connection failed/, 'error message included');
    })->()->get;
};

done_testing;
