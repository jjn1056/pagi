# t/middleware/session/store-cookie.t
#
# Test cookie-based session store (encrypted client-side storage)
#
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;
use PAGI::Middleware::Session::Store::Cookie;

my $loop = IO::Async::Loop->new;
sub run_async (&) { $loop->await($_[0]->()) }

my $SECRET = 'a-secret-key-that-is-at-least-32-bytes-long!!';

subtest 'constructor requires secret' => sub {
    ok(dies { PAGI::Middleware::Session::Store::Cookie->new() },
       'dies without secret');
};

subtest 'set returns encrypted blob (not the ID)' => sub {
    my $store = PAGI::Middleware::Session::Store::Cookie->new(secret => $SECRET);
    my $blob;
    run_async {
        async sub {
            $blob = await $store->set('sess-1', { user_id => 42 });
        }->();
    };

    ok(defined $blob, 'set returns a value');
    isnt($blob, 'sess-1', 'not the session ID');
    unlike($blob, qr/user_id/, 'data is not plaintext');
};

subtest 'get decodes blob back to data' => sub {
    my $store = PAGI::Middleware::Session::Store::Cookie->new(secret => $SECRET);
    my ($blob, $data);
    run_async {
        async sub {
            $blob = await $store->set('sess-1', { user_id => 42, _id => 'sess-1' });
            $data = await $store->get($blob);
        }->();
    };

    ok(defined $data, 'get returns data');
    is($data->{user_id}, 42, 'user_id preserved');
    is($data->{_id}, 'sess-1', 'session ID preserved');
};

subtest 'get returns undef for tampered data' => sub {
    my $store = PAGI::Middleware::Session::Store::Cookie->new(secret => $SECRET);
    my ($blob, $data);
    run_async {
        async sub {
            $blob = await $store->set('sess-1', { user_id => 42 });
            # Tamper with the blob
            my $tampered = $blob;
            substr($tampered, 5, 1) = substr($tampered, 5, 1) eq 'A' ? 'B' : 'A';
            $data = await $store->get($tampered);
        }->();
    };

    is($data, undef, 'tampered data returns undef');
};

subtest 'get returns undef for garbage input' => sub {
    my $store = PAGI::Middleware::Session::Store::Cookie->new(secret => $SECRET);
    my $data;
    run_async {
        async sub {
            $data = await $store->get('not-a-valid-blob');
        }->();
    };
    is($data, undef, 'garbage returns undef');
};

subtest 'get returns undef for undef input' => sub {
    my $store = PAGI::Middleware::Session::Store::Cookie->new(secret => $SECRET);
    my $data;
    run_async {
        async sub {
            $data = await $store->get(undef);
        }->();
    };
    is($data, undef, 'undef returns undef');
};

subtest 'different secrets produce different blobs' => sub {
    my $store1 = PAGI::Middleware::Session::Store::Cookie->new(secret => $SECRET);
    my $store2 = PAGI::Middleware::Session::Store::Cookie->new(secret => 'different-secret-also-32-bytes!!x');

    my ($blob1, $blob2);
    my $data = { user_id => 42 };
    run_async {
        async sub {
            $blob1 = await $store1->set('s', $data);
            $blob2 = await $store2->set('s', $data);
        }->();
    };

    isnt($blob1, $blob2, 'different secrets produce different blobs');
};

subtest 'wrong secret cannot decode' => sub {
    my $store1 = PAGI::Middleware::Session::Store::Cookie->new(secret => $SECRET);
    my $store2 = PAGI::Middleware::Session::Store::Cookie->new(secret => 'wrong-secret-also-32-bytes-long!x');

    my ($blob, $data);
    run_async {
        async sub {
            $blob = await $store1->set('s', { user_id => 42 });
            $data = await $store2->get($blob);
        }->();
    };
    is($data, undef, 'wrong secret returns undef');
};

subtest 'delete is a no-op' => sub {
    my $store = PAGI::Middleware::Session::Store::Cookie->new(secret => $SECRET);
    my $result;
    run_async {
        async sub {
            $result = await $store->delete('anything');
        }->();
    };
    ok(defined $result, 'delete returns something');
};

subtest 'round-trip through middleware pattern' => sub {
    # Simulate: State extracts cookie value, Store decodes it,
    # app modifies session, Store encodes it, State injects cookie
    my $store = PAGI::Middleware::Session::Store::Cookie->new(secret => $SECRET);

    my ($blob, $restored, $blob2, $restored2);
    run_async {
        async sub {
            # First request: new session
            my $session = { _id => 'new-sess', _created => time(), counter => 0 };
            $blob = await $store->set('new-sess', $session);

            # Second request: restore from cookie blob
            $restored = await $store->get($blob);
        }->();
    };
    is($restored->{counter}, 0, 'counter restored');

    run_async {
        async sub {
            # Modify and save again
            $restored->{counter} = 1;
            $blob2 = await $store->set($restored->{_id}, $restored);

            # Third request: verify update persisted
            $restored2 = await $store->get($blob2);
        }->();
    };
    is($restored2->{counter}, 1, 'counter updated');
};

done_testing;
