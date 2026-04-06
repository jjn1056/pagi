#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';
use PAGI::Endpoint::HTTP;
use PAGI::Context;

package CRUDEndpoint {
    use parent 'PAGI::Endpoint::HTTP';
    use Future::AsyncAwait;

    async sub get {
        my ($self, $ctx) = @_;
        await $ctx->response->empty;
    }
    async sub post {
        my ($self, $ctx) = @_;
        await $ctx->response->empty;
    }
    async sub delete {
        my ($self, $ctx) = @_;
        await $ctx->response->empty;
    }
}

my $make_ctx = sub {
    my ($method) = @_;
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $receive = sub { Future->done({ type => 'http.request', body => '' }) };
    my $scope = {
        type    => 'http',
        method  => $method,
        path    => '/test',
        headers => [],
    };
    my $ctx = PAGI::Context->new($scope, $receive, $send);
    return ($ctx, \@sent);
};

subtest 'OPTIONS returns allowed methods' => sub {
    my ($ctx, $sent) = $make_ctx->('OPTIONS');
    my $endpoint = CRUDEndpoint->new;

    $endpoint->dispatch($ctx)->get;

    # The response.start event should have Allow header
    my $start = $sent->[0];
    is($start->{type}, 'http.response.start', 'got response start');
    my $allow;
    for my $pair (@{$start->{headers} // []}) {
        if (lc($pair->[0]) eq 'allow') {
            $allow = $pair->[1];
            last;
        }
    }
    ok(defined $allow, 'Allow header set');
    like($allow, qr/GET/, 'includes GET');
    like($allow, qr/POST/, 'includes POST');
    like($allow, qr/DELETE/, 'includes DELETE');
    like($allow, qr/HEAD/, 'includes HEAD (implicit from GET)');
    like($allow, qr/OPTIONS/, 'includes OPTIONS');
};

subtest '405 response includes Allow header' => sub {
    my ($ctx, $sent) = $make_ctx->('PATCH');
    my $endpoint = CRUDEndpoint->new;

    $endpoint->dispatch($ctx)->get;

    my $start = $sent->[0];
    is($start->{status}, 405, '405 status for unimplemented method');
    my $allow;
    for my $pair (@{$start->{headers} // []}) {
        if (lc($pair->[0]) eq 'allow') {
            $allow = $pair->[1];
            last;
        }
    }
    ok(defined $allow, 'Allow header set on 405');
};

done_testing;
