#!/usr/bin/env perl

use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;

use lib 'lib';

# Load the modules
use PAGI::Middleware;
use PAGI::Middleware::Builder;

# Verify they loaded
ok 1, 'PAGI::Middleware loaded';
ok 1, 'PAGI::Middleware::Builder loaded';

# Create a test loop
my $loop = IO::Async::Loop->new;

# Helper to run async code
sub run_async {
    my ($code) = @_;
    my $future = $code->();
    $loop->await($future);
}

# =============================================================================
# Test: PAGI::Middleware base class
# =============================================================================

subtest 'Middleware base class' => sub {

    # Test: new() creates instance with config
    subtest 'new() stores config' => sub {
        my $mw = PAGI::Middleware->new(option => 'value', foo => 'bar');
        isa_ok $mw, 'PAGI::Middleware';
        is $mw->{config}{option}, 'value', 'config option stored';
        is $mw->{config}{foo}, 'bar', 'config foo stored';
    };

    # Test: wrap() must be overridden
    subtest 'wrap() dies in base class' => sub {
        my $mw = PAGI::Middleware->new;
        my $app = async sub { };
        like dies { $mw->wrap($app) }, qr/Subclass must implement wrap/,
            'wrap() dies with helpful message';
    };

    # Test: modify_scope creates new scope without mutating original
    subtest 'modify_scope does not mutate original' => sub {
        my $mw = PAGI::Middleware->new;
        my $original = { type => 'http', path => '/test' };
        my $modified = $mw->modify_scope($original, { custom => 'value' });

        # Modified scope has additions
        is $modified->{type}, 'http', 'modified has original type';
        is $modified->{path}, '/test', 'modified has original path';
        is $modified->{custom}, 'value', 'modified has additions';

        # Original is unchanged
        ok !exists $original->{custom}, 'original not mutated';

        # They are different references
        isnt $original, $modified, 'different references';
    };

    # Test: intercept_send wraps send callback
    subtest 'intercept_send wraps send' => sub {
        my $mw = PAGI::Middleware->new;
        my @captured;

        my $original_send = async sub ($event) {
            push @captured, { original => $event };
        };

        my $interceptor = async sub ($event, $send) {
            push @captured, { intercepted => $event->{type} };
            # Modify event
            $event->{modified} = 1;
            await $send->($event);
        };

        my $wrapped = $mw->intercept_send($original_send, $interceptor);

        # Test the wrapped send
        run_async(async sub {
            await $wrapped->({ type => 'test.event' });
        });

        is scalar(@captured), 2, 'both interceptor and original called';
        is $captured[0]{intercepted}, 'test.event', 'interceptor saw event';
        ok $captured[1]{original}{modified}, 'original saw modified event';
    };
};

# =============================================================================
# Test: Custom middleware subclass
# =============================================================================

subtest 'Custom middleware subclass' => sub {

    # Create a test middleware that adds a header
    package TestMiddleware::AddHeader {
        use parent 'PAGI::Middleware';
        use Future::AsyncAwait;
        use experimental 'signatures';

        sub wrap ($self, $app) {
            my $header_name  = $self->{config}{name}  // 'x-test';
            my $header_value = $self->{config}{value} // 'added';

            return async sub ($scope, $receive, $send) {
                # Intercept send to add header
                my $wrapped_send = $self->intercept_send($send, async sub ($event, $orig) {
                    if ($event->{type} eq 'http.response.start') {
                        push @{$event->{headers}}, [$header_name, $header_value];
                    }
                    await $orig->($event);
                });

                await $app->($scope, $receive, $wrapped_send);
            };
        }
    }

    # Create a test middleware that modifies scope
    package TestMiddleware::AddToScope {
        use parent 'PAGI::Middleware';
        use Future::AsyncAwait;
        use experimental 'signatures';

        sub wrap ($self, $app) {
            my $key   = $self->{config}{key};
            my $value = $self->{config}{value};

            return async sub ($scope, $receive, $send) {
                my $modified = $self->modify_scope($scope, { $key => $value });
                await $app->($modified, $receive, $send);
            };
        }
    }

    # Test: wrap() returns valid async sub
    subtest 'wrap() returns async sub' => sub {
        my $mw = TestMiddleware::AddHeader->new(name => 'x-custom', value => 'hello');
        my $app = async sub ($scope, $receive, $send) {
            await $send->({ type => 'http.response.start', status => 200, headers => [] });
            await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
        };

        my $wrapped = $mw->wrap($app);
        ok ref($wrapped) eq 'CODE', 'wrap returns coderef';

        # Run the wrapped app
        my @sent;
        run_async(async sub {
            await $wrapped->(
                { type => 'http', path => '/' },
                async sub { { type => 'http.disconnect' } },
                async sub ($event) { push @sent, $event },
            );
        });

        is scalar(@sent), 2, 'sent 2 events';
        is $sent[0]{type}, 'http.response.start', 'first event is response start';

        # Check header was added
        my $found_header = 0;
        for my $h (@{$sent[0]{headers}}) {
            if ($h->[0] eq 'x-custom' && $h->[1] eq 'hello') {
                $found_header = 1;
                last;
            }
        }
        ok $found_header, 'custom header was added';
    };

    # Test: middleware modifies scope without mutating original
    subtest 'middleware modifies scope without mutation' => sub {
        my $mw = TestMiddleware::AddToScope->new(key => 'custom_data', value => 'test_value');

        my $original_scope = { type => 'http', path => '/test' };
        my $received_scope;

        my $app = async sub ($scope, $receive, $send) {
            $received_scope = $scope;
            await $send->({ type => 'http.response.start', status => 200, headers => [] });
            await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
        };

        my $wrapped = $mw->wrap($app);

        run_async(async sub {
            await $wrapped->(
                $original_scope,
                async sub { { type => 'http.disconnect' } },
                async sub ($event) { },
            );
        });

        # Inner app received modified scope
        is $received_scope->{custom_data}, 'test_value', 'inner app got custom data';

        # Original scope unchanged
        ok !exists $original_scope->{custom_data}, 'original scope not mutated';
    };
};

# =============================================================================
# Test: PAGI::Middleware::Builder
# =============================================================================

subtest 'Middleware Builder' => sub {

    # Test: builder {} DSL
    subtest 'builder {} creates composed app' => sub {
        # Simple inline middleware for testing
        package TestMiddleware::Counter {
            use parent 'PAGI::Middleware';
            use Future::AsyncAwait;
            use experimental 'signatures';
            our $call_order = [];

            sub wrap ($self, $app) {
                my $name = $self->{config}{name};
                return async sub ($scope, $receive, $send) {
                    push @$call_order, "enter:$name";
                    await $app->($scope, $receive, $send);
                    push @$call_order, "exit:$name";
                };
            }
        }

        $TestMiddleware::Counter::call_order = [];

        # Build using DSL
        my $inner_app = async sub ($scope, $receive, $send) {
            push @$TestMiddleware::Counter::call_order, "app";
            await $send->({ type => 'http.response.start', status => 200, headers => [] });
            await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
        };

        # Manually compose (simulating builder)
        my $builder = PAGI::Middleware::Builder->new;
        $builder->add_middleware('TestMiddleware::Counter', name => 'A');
        $builder->add_middleware('TestMiddleware::Counter', name => 'B');
        my $app = $builder->to_app($inner_app);

        run_async(async sub {
            await $app->(
                { type => 'http', path => '/' },
                async sub { { type => 'http.disconnect' } },
                async sub ($event) { },
            );
        });

        # Verify middleware execution order
        is $TestMiddleware::Counter::call_order,
            ['enter:A', 'enter:B', 'app', 'exit:B', 'exit:A'],
            'middleware executed in correct order';
    };

    # Test: enable_if conditionally applies middleware
    subtest 'enable_if conditionally applies middleware' => sub {
        package TestMiddleware::Marker {
            use parent 'PAGI::Middleware';
            use Future::AsyncAwait;
            use experimental 'signatures';
            our $was_applied = 0;

            sub wrap ($self, $app) {
                return async sub ($scope, $receive, $send) {
                    $was_applied = 1;
                    await $app->($scope, $receive, $send);
                };
            }
        }

        my $inner_app = async sub ($scope, $receive, $send) {
            await $send->({ type => 'http.response.start', status => 200, headers => [] });
            await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
        };

        # Condition: only apply for /api/ paths
        my $builder = PAGI::Middleware::Builder->new;
        $builder->add_middleware_if(
            sub { $_[0]->{path} =~ m{^/api/} },
            'TestMiddleware::Marker',
        );
        my $app = $builder->to_app($inner_app);

        # Test 1: path matches condition
        $TestMiddleware::Marker::was_applied = 0;
        run_async(async sub {
            await $app->(
                { type => 'http', path => '/api/users' },
                async sub { { type => 'http.disconnect' } },
                async sub ($event) { },
            );
        });
        ok $TestMiddleware::Marker::was_applied, 'middleware applied for /api/ path';

        # Test 2: path does not match condition
        $TestMiddleware::Marker::was_applied = 0;
        run_async(async sub {
            await $app->(
                { type => 'http', path => '/web/home' },
                async sub { { type => 'http.disconnect' } },
                async sub ($event) { },
            );
        });
        ok !$TestMiddleware::Marker::was_applied, 'middleware skipped for non-/api/ path';
    };

    # Test: mount routes by path prefix
    subtest 'mount routes by path prefix' => sub {
        my $api_called = 0;
        my $api_path;
        my $api_root_path;

        my $api_app = async sub ($scope, $receive, $send) {
            $api_called = 1;
            $api_path = $scope->{path};
            $api_root_path = $scope->{root_path};
            await $send->({ type => 'http.response.start', status => 200, headers => [] });
            await $send->({ type => 'http.response.body', body => 'API', more => 0 });
        };

        my $main_called = 0;
        my $main_app = async sub ($scope, $receive, $send) {
            $main_called = 1;
            await $send->({ type => 'http.response.start', status => 200, headers => [] });
            await $send->({ type => 'http.response.body', body => 'Main', more => 0 });
        };

        my $builder = PAGI::Middleware::Builder->new;
        $builder->add_mount('/api', $api_app);
        my $app = $builder->to_app($main_app);

        # Test 1: request to /api/users should route to api_app
        $api_called = $main_called = 0;
        run_async(async sub {
            await $app->(
                { type => 'http', path => '/api/users', root_path => '' },
                async sub { { type => 'http.disconnect' } },
                async sub ($event) { },
            );
        });
        ok $api_called, 'API app was called';
        ok !$main_called, 'main app was not called';
        is $api_path, '/users', 'path adjusted for mounted app';
        is $api_root_path, '/api', 'root_path set correctly';

        # Test 2: request to /web/home should route to main_app
        $api_called = $main_called = 0;
        run_async(async sub {
            await $app->(
                { type => 'http', path => '/web/home', root_path => '' },
                async sub { { type => 'http.disconnect' } },
                async sub ($event) { },
            );
        });
        ok !$api_called, 'API app was not called';
        ok $main_called, 'main app was called';

        # Test 3: exact mount path should match
        $api_called = $main_called = 0;
        run_async(async sub {
            await $app->(
                { type => 'http', path => '/api', root_path => '' },
                async sub { { type => 'http.disconnect' } },
                async sub ($event) { },
            );
        });
        ok $api_called, 'API app was called for exact path';
        is $api_path, '/', 'path is / for exact mount match';
    };
};

# =============================================================================
# Test: buffer_request_body helper
# =============================================================================

subtest 'buffer_request_body helper' => sub {
    my $mw = PAGI::Middleware->new;

    # Create a receive that returns body in chunks
    my @events = (
        { type => 'http.request', body => 'Hello, ', more => 1 },
        { type => 'http.request', body => 'World!', more => 0 },
    );
    my $idx = 0;
    my $receive = async sub { $events[$idx++] };

    my ($body, $final_event);
    run_async(async sub {
        ($body, $final_event) = await $mw->buffer_request_body($receive);
    });

    is $body, 'Hello, World!', 'body chunks combined';
    is $final_event->{more}, 0, 'final event has more => 0';
};

done_testing;
