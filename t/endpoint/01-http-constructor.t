#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';

subtest 'can create endpoint subclass' => sub {
    require PAGI::Endpoint::HTTP;

    package MyEndpoint {
        use parent 'PAGI::Endpoint::HTTP';
        use Future::AsyncAwait;

        async sub get {
            my ($self, $ctx) = @_;
            await $ctx->response->text("Hello");
        }
    }

    my $endpoint = MyEndpoint->new;
    isa_ok($endpoint, 'PAGI::Endpoint::HTTP');
    isa_ok($endpoint, 'MyEndpoint');
};

subtest 'context_class has default' => sub {
    require PAGI::Endpoint::HTTP;

    is(PAGI::Endpoint::HTTP->context_class, 'PAGI::Context', 'default context_class');
};

subtest 'subclass can override context_class' => sub {
    package CustomEndpoint {
        use parent 'PAGI::Endpoint::HTTP';

        sub context_class { 'My::Context' }
    }

    is(CustomEndpoint->context_class, 'My::Context', 'custom context_class');
};

done_testing;
