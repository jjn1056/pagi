use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;

use lib 'lib';
use PAGI::Utils qw(handle_lifespan);
use PAGI::App::Router;
use PAGI::Test::Client;

subtest 'handle_lifespan runs hooks in order' => sub {
    my @events = (
        { type => 'lifespan.startup' },
        { type => 'lifespan.shutdown' },
    );
    my @sent;
    my @order;

    my $scope = {
        type  => 'lifespan',
        state => {},
        'pagi.lifespan.handlers' => [
            {
                startup => async sub {
                    my ($state) = @_;
                    push @order, 'first_start';
                    $state->{first} = 1;
                },
                shutdown => async sub {
                    my ($state) = @_;
                    push @order, 'first_stop';
                    $state->{first_stop} = 1;
                },
            },
        ],
    };

    my $receive = async sub { return shift @events; };
    my $send = async sub {
        my ($event) = @_;
        push @sent, $event;
    };

    handle_lifespan(
        $scope,
        $receive,
        $send,
        startup => async sub {
            my ($state) = @_;
            push @order, 'second_start';
            $state->{second} = 1;
        },
        shutdown => async sub {
            my ($state) = @_;
            push @order, 'second_stop';
            $state->{second_stop} = 1;
        },
    )->get;

    is \@order, ['first_start', 'second_start', 'second_stop', 'first_stop'],
        'startup runs in order, shutdown runs reverse';
    is [map { $_->{type} } @sent],
        ['lifespan.startup.complete', 'lifespan.shutdown.complete'],
        'sends completion events';
    ok $scope->{state}{first}, 'state updated by first startup';
    ok $scope->{state}{second}, 'state updated by second startup';
};

subtest 'handle_lifespan aggregates nested apps' => sub {
    my @events = (
        { type => 'lifespan.startup' },
        { type => 'lifespan.shutdown' },
    );
    my @sent;
    my @order;

    my $register_hooks = sub {
        my ($scope, $name) = @_;
        my $handlers = $scope->{'pagi.lifespan.handlers'} //= [];
        push @$handlers, {
            startup => async sub {
                push @order, $name . "_start";
            },
            shutdown => async sub {
                push @order, $name . "_stop";
            },
        };
    };

    my $base_app = async sub {
        my ($scope, $receive, $send) = @_;
        return unless ($scope->{type} // '') eq 'lifespan';
        await handle_lifespan($scope, $receive, $send);
    };

    my $wrap = sub {
        my ($name, $app) = @_;
        return async sub {
            my ($scope, $receive, $send) = @_;
            if (($scope->{type} // '') eq 'lifespan') {
                $register_hooks->($scope, $name);
            }
            return await $app->($scope, $receive, $send);
        };
    };

    my $app = $wrap->('outer', $wrap->('middle', $wrap->('inner', $base_app)));

    my $scope = { type => 'lifespan', state => {} };
    my $receive = async sub { return shift @events; };
    my $send = async sub {
        my ($event) = @_;
        push @sent, $event;
    };

    $app->($scope, $receive, $send)->get;

    is \@order,
        ['outer_start', 'middle_start', 'inner_start', 'inner_stop', 'middle_stop', 'outer_stop'],
        'startup runs outer->inner, shutdown runs inner->outer';
    is [map { $_->{type} } @sent],
        ['lifespan.startup.complete', 'lifespan.shutdown.complete'],
        'sends completion events';
};

subtest 'pod-style usage with Test::Client' => sub {
    my @order;

    my $router = PAGI::App::Router->new;
    $router->get('/' => async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [],
        });
        await $send->({
            type => 'http.response.body',
            body => 'ok',
            more => 0,
        });
    });
    my $router_app = $router->to_app;

    my $app = async sub {
        my ($scope, $receive, $send) = @_;

        return await handle_lifespan($scope, $receive, $send,
            startup  => async sub { push @order, 'startup' },
            shutdown => async sub { push @order, 'shutdown' },
        ) if ($scope->{type} // '') eq 'lifespan';

        await $router_app->($scope, $receive, $send);
    };

    my $client = PAGI::Test::Client->new(app => $app, lifespan => 1);
    $client->start;
    my $res = $client->get('/');
    $client->stop;

    is $res->text, 'ok', 'http path still works';
    is \@order, ['startup', 'shutdown'], 'lifespan hooks ran';
};

subtest 'handle_lifespan in inner app with outer hooks' => sub {
    my @order;

    my $router = PAGI::App::Router->new;
    $router->get('/' => async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [],
        });
        await $send->({
            type => 'http.response.body',
            body => 'ok',
            more => 0,
        });
    });
    my $router_app = $router->to_app;

    my $inner_app = async sub {
        my ($scope, $receive, $send) = @_;

        return await handle_lifespan($scope, $receive, $send,
            startup  => async sub { push @order, 'inner_start' },
            shutdown => async sub { push @order, 'inner_stop' },
        ) if ($scope->{type} // '') eq 'lifespan';

        await $router_app->($scope, $receive, $send);
    };

    my $outer_app = async sub {
        my ($scope, $receive, $send) = @_;
        if (($scope->{type} // '') eq 'lifespan') {
            my $handlers = $scope->{'pagi.lifespan.handlers'} //= [];
            push @$handlers, {
                startup  => async sub { push @order, 'outer_start' },
                shutdown => async sub { push @order, 'outer_stop' },
            };
        }
        await $inner_app->($scope, $receive, $send);
    };

    my $client = PAGI::Test::Client->new(app => $outer_app, lifespan => 1);
    $client->start;
    my $res = $client->get('/');
    $client->stop;

    is $res->text, 'ok', 'http path still works';
    is \@order, ['outer_start', 'inner_start', 'inner_stop', 'outer_stop'],
        'inner handler runs after outer hook registration';
};

subtest 'handle_lifespan croaks for non-lifespan scope' => sub {
    my $scope = { type => 'http' };
    my $receive = async sub { return { type => 'http.disconnect' } };
    my $send = async sub { };

    like dies { handle_lifespan($scope, $receive, $send)->get },
        qr/handle_lifespan called with scope type 'http'.*expected 'lifespan'/,
        'croaks with helpful message for wrong scope type';
};

subtest 'handle_lifespan reports startup failure' => sub {
    my @events = (
        { type => 'lifespan.startup' },
        { type => 'lifespan.shutdown' },
    );
    my @sent;

    my $scope = { type => 'lifespan' };
    my $receive = async sub { return shift @events; };
    my $send = async sub {
        my ($event) = @_;
        push @sent, $event;
    };

    handle_lifespan(
        $scope,
        $receive,
        $send,
        startup => async sub {
            die "boom";
        },
    )->get;

    is scalar(@sent), 1, 'only one event sent on startup failure';
    is $sent[0]{type}, 'lifespan.startup.failed', 'startup failure reported';
    like $sent[0]{message}, qr/boom/, 'error message included';
};

done_testing;
