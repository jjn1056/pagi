#!/usr/bin/env perl

use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future;
use Future::AsyncAwait;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

# =============================================================================
# PAGI::Simple Async Service Tests
#
# Tests that services can use async methods with Future::AsyncAwait
# =============================================================================

use lib 'lib';
use Scalar::Util qw(blessed refaddr);
use PAGI::Simple::Service::Factory;
use PAGI::Simple::Service::PerRequest;
use PAGI::Simple::Service::PerApp;

# Mock context with required methods
{
    package MockContext;
    sub new { bless { stash => {}, _cleanup => [] }, shift }
    sub stash { shift->{stash} }
    sub _register_service_for_cleanup { push @{shift->{_cleanup}}, shift }
}

# -----------------------------------------------------------------------------
# Test Service Classes (defined inline for testing)
# -----------------------------------------------------------------------------

# Factory service with async methods
{
    package TestService::AsyncFetcher;
    use parent 'PAGI::Simple::Service::Factory';
    use Future::AsyncAwait;
    use experimental 'signatures';

    async sub fetch_user ($self, $id) {
        # Simulate async - in real code this would be a DB call
        return { id => $id, name => "User $id" };
    }

    async sub fetch_all ($self) {
        my @users;
        for my $id (1..3) {
            push @users, await $self->fetch_user($id);
        }
        return \@users;
    }
}

# PerRequest service with async methods
{
    package TestService::AsyncProfile;
    use parent 'PAGI::Simple::Service::PerRequest';
    use Future::AsyncAwait;
    use experimental 'signatures';

    my $instance_count = 0;

    sub new ($class, %args) {
        $instance_count++;
        my $self = $class->SUPER::new(%args);
        $self->{instance_num} = $instance_count;
        return $self;
    }

    async sub get_profile ($self, $id) {
        return {
            id => $id,
            instance => $self->{instance_num},
            loaded_at => time(),
        };
    }

    sub instance_num ($self) { $self->{instance_num} }
    sub reset_count { $instance_count = 0; }
}

# PerApp singleton with async methods
{
    package TestService::AsyncCache;
    use parent 'PAGI::Simple::Service::PerApp';
    use Future::AsyncAwait;
    use experimental 'signatures';

    my %cache;

    async sub get ($self, $key) {
        return $cache{$key};
    }

    async sub set ($self, $key, $value) {
        $cache{$key} = $value;
        return 1;
    }

    sub clear { %cache = (); }
}

# =============================================================================
# Test 1: Factory service with async methods works
# =============================================================================
subtest 'Factory service with async methods' => sub {
    # Mock app and context
    my $mock_app = bless {}, 'MockApp';
    my $mock_context = MockContext->new();

    # Initialize service
    my $factory = TestService::AsyncFetcher->init_service($mock_app, {});
    ok ref($factory) eq 'CODE', 'Factory returns coderef';

    # Get instance
    my $service = $factory->($mock_context);
    ok $service, 'Got service instance';
    isa_ok $service, 'TestService::AsyncFetcher';

    # Test async method
    my $user = $service->fetch_user(42)->get;
    is $user->{id}, 42, 'Async fetch_user returns correct id';
    is $user->{name}, 'User 42', 'Async fetch_user returns correct name';

    # Test async method with multiple awaits
    my $users = $service->fetch_all->get;
    is scalar(@$users), 3, 'fetch_all returns 3 users';
    is $users->[0]{id}, 1, 'First user id correct';
    is $users->[2]{id}, 3, 'Third user id correct';
};

# =============================================================================
# Test 2: PerRequest service with async methods (caching works)
# =============================================================================
subtest 'PerRequest service with async methods' => sub {
    TestService::AsyncProfile->reset_count();

    my $mock_app = bless {}, 'MockApp';
    my $mock_context = MockContext->new();

    # Initialize service
    my $factory = TestService::AsyncProfile->init_service($mock_app, {});

    # Get instance twice
    my $s1 = $factory->($mock_context);
    my $s2 = $factory->($mock_context);

    is refaddr($s1), refaddr($s2), 'PerRequest returns same instance';
    is $s1->instance_num, 1, 'Only instantiated once';

    # Test async method on cached instance
    my $profile = $s1->get_profile(123)->get;
    is $profile->{id}, 123, 'Async method works on cached instance';
    is $profile->{instance}, 1, 'Profile has correct instance number';
};

# =============================================================================
# Test 3: PerApp singleton with async methods
# =============================================================================
subtest 'PerApp singleton with async methods' => sub {
    TestService::AsyncCache->clear();

    my $mock_app = bless {}, 'MockApp';

    # Initialize service (returns singleton)
    my $singleton = TestService::AsyncCache->init_service($mock_app, {});
    ok blessed($singleton), 'PerApp returns instance (not coderef)';

    # Test async set/get
    $singleton->set('foo', 'bar')->get;
    my $value = $singleton->get('foo')->get;
    is $value, 'bar', 'Async cache set/get works';

    # Get another reference - should be same instance
    my $singleton2 = TestService::AsyncCache->init_service($mock_app, {});
    is $singleton2, $singleton, 'PerApp always returns same instance';

    my $value2 = $singleton2->get('foo')->get;
    is $value2, 'bar', 'Singleton preserves state';
};

# =============================================================================
# Test 4: Different requests get different PerRequest instances
# =============================================================================
subtest 'Different requests get different PerRequest instances' => sub {
    TestService::AsyncProfile->reset_count();

    my $mock_app = bless {}, 'MockApp';

    # First "request"
    my $context1 = MockContext->new();
    my $factory = TestService::AsyncProfile->init_service($mock_app, {});
    my $s1 = $factory->($context1);

    # Second "request" (new context with fresh stash)
    my $context2 = MockContext->new();
    my $s2 = $factory->($context2);

    isnt refaddr($s1), refaddr($s2), 'Different requests get different instances';
    is $s1->instance_num, 1, 'First request instance is #1';
    is $s2->instance_num, 2, 'Second request instance is #2';

    # Both can call async methods
    my $p1 = $s1->get_profile(1)->get;
    my $p2 = $s2->get_profile(2)->get;

    is $p1->{instance}, 1, 'First profile from instance #1';
    is $p2->{instance}, 2, 'Second profile from instance #2';
};

# =============================================================================
# Test 5: Service can call other async operations
# =============================================================================
subtest 'Service can call other async operations' => sub {
    # Service that does multiple async operations
    {
        package TestService::MultiAsync;
        use parent 'PAGI::Simple::Service::Factory';
        use Future::AsyncAwait;
        use experimental 'signatures';

        async sub complex_operation ($self) {
            # Simulate multiple async steps
            my $step1 = await $self->_step1();
            my $step2 = await $self->_step2($step1);
            my $step3 = await $self->_step3($step2);
            return { result => $step3 };
        }

        async sub _step1 ($self) { return 10; }
        async sub _step2 ($self, $val) { return $val * 2; }
        async sub _step3 ($self, $val) { return $val + 5; }
    }

    my $mock_app = bless {}, 'MockApp';
    my $mock_context = MockContext->new();

    my $factory = TestService::MultiAsync->init_service($mock_app, {});
    my $service = $factory->($mock_context);

    my $result = $service->complex_operation->get;
    is $result->{result}, 25, 'Complex async operation works (10*2+5=25)';
};

done_testing;
