#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;

use PAGI::Middleware::Session::Store;
use PAGI::Middleware::Session::Store::Memory;

my $loop = IO::Async::Loop->new;
sub run_async (&) { $loop->await($_[0]->()) }

# ===================
# Store base class
# ===================

subtest 'Store base class - get dies' => sub {
    my $store = PAGI::Middleware::Session::Store->new();
    like dies { $store->get('id123') }, qr/must implement/, 'get() dies with must implement';
};

subtest 'Store base class - set dies' => sub {
    my $store = PAGI::Middleware::Session::Store->new();
    like dies { $store->set('id123', {}) }, qr/must implement/, 'set() dies with must implement';
};

subtest 'Store base class - delete dies' => sub {
    my $store = PAGI::Middleware::Session::Store->new();
    like dies { $store->delete('id123') }, qr/must implement/, 'delete() dies with must implement';
};

# ===================
# Store::Memory - get missing key
# ===================

subtest 'Store::Memory - get returns undef for missing key' => sub {
    PAGI::Middleware::Session::Store::Memory->clear_all();
    my $store = PAGI::Middleware::Session::Store::Memory->new();

    run_async {
        async sub {
            my $result = await $store->get('nonexistent');
            is $result, undef, 'get returns undef for missing key';
        }->();
    };
};

# ===================
# Store::Memory - set and get round-trip
# ===================

subtest 'Store::Memory - set and get round-trip' => sub {
    PAGI::Middleware::Session::Store::Memory->clear_all();
    my $store = PAGI::Middleware::Session::Store::Memory->new();

    run_async {
        async sub {
            my $data = { user_id => 42, name => 'Alice' };
            my $set_result = await $store->set('sess1', $data);
            is $set_result, 'sess1', 'set returns transport value (session ID)';

            my $got = await $store->get('sess1');
            is $got, { user_id => 42, name => 'Alice' }, 'get returns stored data';
        }->();
    };
};

# ===================
# Store::Memory - delete removes session
# ===================

subtest 'Store::Memory - delete removes session' => sub {
    PAGI::Middleware::Session::Store::Memory->clear_all();
    my $store = PAGI::Middleware::Session::Store::Memory->new();

    run_async {
        async sub {
            await $store->set('sess_del', { foo => 'bar' });
            my $del_result = await $store->delete('sess_del');
            is $del_result, 1, 'delete returns 1';

            my $got = await $store->get('sess_del');
            is $got, undef, 'get returns undef after delete';
        }->();
    };
};

# ===================
# Store::Memory - separate instances share state
# ===================

subtest 'Store::Memory - separate instances share state' => sub {
    PAGI::Middleware::Session::Store::Memory->clear_all();
    my $store_a = PAGI::Middleware::Session::Store::Memory->new();
    my $store_b = PAGI::Middleware::Session::Store::Memory->new();

    run_async {
        async sub {
            await $store_a->set('shared_key', { shared => 1 });
            my $got = await $store_b->get('shared_key');
            is $got, { shared => 1 }, 'second instance sees data from first instance';
        }->();
    };
};

# ===================
# Store::Memory - clear_all removes everything
# ===================

subtest 'Store::Memory - clear_all removes everything' => sub {
    my $store = PAGI::Middleware::Session::Store::Memory->new();

    run_async {
        async sub {
            await $store->set('key1', { a => 1 });
            await $store->set('key2', { b => 2 });

            PAGI::Middleware::Session::Store::Memory->clear_all();

            my $got1 = await $store->get('key1');
            my $got2 = await $store->get('key2');
            is $got1, undef, 'key1 gone after clear_all';
            is $got2, undef, 'key2 gone after clear_all';
        }->();
    };
};

# ===================
# Store::Memory - return values are Futures
# ===================

subtest 'Store::Memory - return values are Future objects' => sub {
    PAGI::Middleware::Session::Store::Memory->clear_all();
    my $store = PAGI::Middleware::Session::Store::Memory->new();

    my $get_f = $store->get('any');
    isa_ok $get_f, ['Future'], 'get() returns a Future';

    my $set_f = $store->set('any', { x => 1 });
    isa_ok $set_f, ['Future'], 'set() returns a Future';

    my $del_f = $store->delete('any');
    isa_ok $del_f, ['Future'], 'delete() returns a Future';
};

done_testing;
