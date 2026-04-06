#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use PAGI::Context;

subtest 'custom _type_map adds new protocol' => sub {
    {
        package TestExt::Context;
        our @ISA = ('PAGI::Context');

        sub _type_map {
            my ($class) = @_;
            return {
                %{ $class->SUPER::_type_map },
                grpc => 'TestExt::Context::GRPC',
            };
        }

        package TestExt::Context::GRPC;
        our @ISA = ('PAGI::Context');

        sub grpc_method { shift->{scope}{grpc_method} }
    }

    my $ctx = TestExt::Context->new(
        { type => 'grpc', grpc_method => 'users.List', headers => [] },
        sub {}, sub {},
    );

    isa_ok($ctx, 'PAGI::Context');
    isa_ok($ctx, 'TestExt::Context::GRPC');
    is($ctx->grpc_method, 'users.List', 'custom method works');
    is($ctx->type, 'grpc', 'type accessor works');
    is($ctx->path, undef, 'path is undef (no path in gRPC)');

    # Standard types still work
    my $http = TestExt::Context->new(
        { type => 'http', method => 'GET', path => '/', headers => [] },
        sub {}, sub {},
    );
    isa_ok($http, 'PAGI::Context::HTTP');
};

subtest 'custom _type_map replaces built-in type' => sub {
    {
        package TestReplace::Context;
        our @ISA = ('PAGI::Context');

        sub _type_map {
            my ($class) = @_;
            return {
                %{ $class->SUPER::_type_map },
                http => 'TestReplace::Context::HTTP',
            };
        }

        package TestReplace::Context::HTTP;
        our @ISA = ('PAGI::Context::HTTP');

        sub current_user {
            my ($self) = @_;
            return $self->stash->get('current_user', undef);
        }
    }

    my $ctx = TestReplace::Context->new(
        { type => 'http', method => 'GET', path => '/', headers => [] },
        sub {}, sub {},
    );

    isa_ok($ctx, 'PAGI::Context');
    isa_ok($ctx, 'PAGI::Context::HTTP');
    isa_ok($ctx, 'TestReplace::Context::HTTP');
    ok($ctx->can('request'), 'inherits HTTP request method');
    ok($ctx->can('current_user'), 'has custom method');
    is($ctx->current_user, undef, 'custom method works');
};

subtest 'custom _resolve_class overrides resolution logic' => sub {
    {
        package TestResolve::Context;
        our @ISA = ('PAGI::Context');

        sub _resolve_class {
            my ($class, $scope) = @_;
            # Route WebSocket with specific subprotocol to custom class
            if (($scope->{type} // '') eq 'websocket') {
                for my $pair (@{$scope->{headers} // []}) {
                    if (lc($pair->[0]) eq 'sec-websocket-protocol'
                        && $pair->[1] eq 'jsonrpc') {
                        return 'TestResolve::Context::JsonRPC';
                    }
                }
            }
            return $class->SUPER::_resolve_class($scope);
        }

        package TestResolve::Context::JsonRPC;
        our @ISA = ('PAGI::Context::WebSocket');

        sub is_jsonrpc { 1 }
    }

    my $jsonrpc = TestResolve::Context->new(
        {
            type    => 'websocket',
            path    => '/rpc',
            headers => [['sec-websocket-protocol', 'jsonrpc']],
        },
        sub {}, sub {},
    );

    isa_ok($jsonrpc, 'TestResolve::Context::JsonRPC');
    isa_ok($jsonrpc, 'PAGI::Context::WebSocket');
    isa_ok($jsonrpc, 'PAGI::Context');
    ok($jsonrpc->is_jsonrpc, 'custom method available');
    ok($jsonrpc->can('websocket'), 'inherits websocket accessor');

    # Non-jsonrpc WebSocket still resolves normally
    my $plain_ws = TestResolve::Context->new(
        { type => 'websocket', path => '/ws', headers => [] },
        sub {}, sub {},
    );
    isa_ok($plain_ws, 'PAGI::Context::WebSocket');
    ok(!$plain_ws->can('is_jsonrpc'), 'plain WS does not have custom method');
};

subtest 'unknown type from custom factory falls back to HTTP' => sub {
    my $ctx = PAGI::Context->new(
        { type => 'carrier_pigeon', headers => [] },
        sub {}, sub {},
    );
    isa_ok($ctx, 'PAGI::Context::HTTP');
};

done_testing;
