#!/usr/bin/env perl

# =============================================================================
# Test: Middleware Builder class name resolution
#
# Tests the ^ prefix for fully-qualified class names and ensures nested
# namespace middleware (like Auth::Basic) works correctly.
# =============================================================================

use strict;
use warnings;
use Test2::V0;

use lib 'lib';
use PAGI::Middleware::Builder;

# =============================================================================
# Test _resolve_middleware directly
# =============================================================================

subtest 'middleware class resolution' => sub {
    my $builder = PAGI::Middleware::Builder->new;

    # Simple names get prefixed
    is $builder->_resolve_middleware('GZIP'),
        'PAGI::Middleware::GZIP',
        'simple name gets PAGI::Middleware:: prefix';

    is $builder->_resolve_middleware('ContentLength'),
        'PAGI::Middleware::ContentLength',
        'ContentLength gets prefix';

    # Nested namespaces also get prefixed (the bug fix)
    is $builder->_resolve_middleware('Auth::Basic'),
        'PAGI::Middleware::Auth::Basic',
        'Auth::Basic gets PAGI::Middleware:: prefix';

    is $builder->_resolve_middleware('Auth::Bearer'),
        'PAGI::Middleware::Auth::Bearer',
        'Auth::Bearer gets PAGI::Middleware:: prefix';

    is $builder->_resolve_middleware('WebSocket::Compression'),
        'PAGI::Middleware::WebSocket::Compression',
        'WebSocket::Compression gets PAGI::Middleware:: prefix';

    is $builder->_resolve_middleware('SSE::Retry'),
        'PAGI::Middleware::SSE::Retry',
        'SSE::Retry gets PAGI::Middleware:: prefix';

    # Caret prefix prevents automatic prefixing
    is $builder->_resolve_middleware('^My::Custom::Middleware'),
        'My::Custom::Middleware',
        '^My::Custom::Middleware uses exact class name';

    is $builder->_resolve_middleware('^TopLevel'),
        'TopLevel',
        '^TopLevel uses exact class name (top-level)';

    is $builder->_resolve_middleware('^Some::Deep::Nested::Class'),
        'Some::Deep::Nested::Class',
        'deeply nested class with ^ works';
};

# =============================================================================
# Test with actual middleware loading
# =============================================================================

subtest 'loading real nested middleware' => sub {
    my $builder = PAGI::Middleware::Builder->new;

    # These should resolve and load correctly
    my $class1 = $builder->_resolve_middleware('Auth::Basic');
    is $class1, 'PAGI::Middleware::Auth::Basic', 'Auth::Basic resolves correctly';
    ok $class1->can('wrap'), 'Auth::Basic class loaded and has wrap method';

    my $class2 = $builder->_resolve_middleware('WebSocket::Compression');
    is $class2, 'PAGI::Middleware::WebSocket::Compression', 'WebSocket::Compression resolves correctly';
    ok $class2->can('wrap'), 'WebSocket::Compression class loaded and has wrap method';
};

done_testing;
