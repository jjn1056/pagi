#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Scalar::Util 'blessed';

use lib 'lib';
use PAGI::Simple::StructuredParams;

# ============================================================================
# BASIC REQUIRED FUNCTIONALITY
# ============================================================================

subtest 'required() returns self for chaining' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => { name => 'John' });
    my $result = $sp->required('name');
    is $result, $sp, 'required() returns $self';
};

subtest 'required() field present - passes' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => { name => 'John' });
    my $data = $sp->required('name')->to_hash;
    is $data, { name => 'John' }, 'data returned when required field present';
};

subtest 'required() field missing - throws' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => { other => 'value' });
    my $err = dies { $sp->required('name')->to_hash };
    like $err, qr/name/i, 'Error mentions missing field';
};

subtest 'required() field empty string - throws' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => { name => '' });
    my $err = dies { $sp->required('name')->to_hash };
    like $err, qr/name/i, 'Empty string fails required';
};

subtest 'required() field undef - throws' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => { name => undef });
    my $err = dies { $sp->required('name')->to_hash };
    like $err, qr/name/i, 'undef fails required';
};

# ============================================================================
# MULTIPLE REQUIRED FIELDS
# ============================================================================

subtest 'multiple required fields - all present' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        username => 'jdoe',
        email => 'jdoe@example.com',
    });
    my $data = $sp->required('username', 'email')->to_hash;
    ok exists $data->{username}, 'username present';
    ok exists $data->{email}, 'email present';
};

subtest 'multiple required fields - one missing' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => { username => 'jdoe' });
    my $err = dies { $sp->required('username', 'email')->to_hash };
    like $err, qr/email/i, 'Error mentions missing email';
};

subtest 'multiple required fields - multiple missing' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {});
    my $err = dies { $sp->required('a', 'b', 'c')->to_hash };
    like $err, qr/a/, 'Error mentions a';
    like $err, qr/b/, 'Error mentions b';
    like $err, qr/c/, 'Error mentions c';
};

subtest 'multiple required() calls accumulate' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => { a => 1, b => 2 });
    $sp->required('a');
    $sp->required('b');
    my $data = $sp->to_hash;
    is $data, { a => 1, b => 2 }, 'Multiple required() calls satisfied';
};

# ============================================================================
# REQUIRED WITH PERMITTED (D4)
# ============================================================================

subtest 'required with permitted - D4: required checked AFTER filtering' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        name => 'John',
        age => 42,
    });
    # Per D4: required() validates the FINAL result after permitted() filtering
    my $data = $sp->permitted('name', 'age')->required('name')->to_hash;
    is $data, { name => 'John', age => 42 }, 'data returned when required in permitted';
};

subtest 'required field not in permitted - should fail (D4 implication)' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        name => 'John',
        secret => 'value',
    });
    my $err = dies { $sp->permitted('name')->required('secret')->to_hash };
    like $err, qr/secret/i, 'Required field not in permitted fails';
};

# ============================================================================
# REQUIRED WITH NAMESPACE
# ============================================================================

subtest 'required with namespace - present' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'person.name' => 'John',
    });
    my $data = $sp->namespace('person')->required('name')->to_hash;
    is $data, { name => 'John' }, 'namespace + required works';
};

subtest 'required with namespace - missing' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'other.name' => 'John',
    });
    my $err = dies { $sp->namespace('person')->required('name')->to_hash };
    like $err, qr/name/i, 'Error when namespaced field missing';
};

# ============================================================================
# EDGE CASES
# ============================================================================

subtest 'required zero value passes (0 is not empty)' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => { count => 0 });
    my $data = $sp->required('count')->to_hash;
    is $data->{count}, 0, 'Zero passes required';
};

subtest 'required "0" string passes' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => { value => '0' });
    my $data = $sp->required('value')->to_hash;
    is $data->{value}, '0', '"0" string passes required';
};

subtest 'required whitespace-only string passes' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => { value => '   ' });
    my $data = $sp->required('value')->to_hash;
    is $data->{value}, '   ', 'Whitespace passes required (not empty)';
};

# ============================================================================
# EXCEPTION OBJECT
# ============================================================================

subtest 'exception has correct status code' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {});
    my $err;
    eval { $sp->required('name')->to_hash };
    $err = $@;

    ok blessed($err), 'Exception is an object';
    isa_ok $err, 'PAGI::Simple::Exception';
    is $err->status, 400, 'Exception has 400 status';
    like $err->message, qr/name/, 'Exception message mentions field';
};

subtest 'exception stringifies to message' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {});
    my $err;
    eval { $sp->required('name')->to_hash };
    $err = $@;

    like "$err", qr/Missing required parameters.*name/, 'Exception stringifies correctly';
};

# ============================================================================
# FULL CHAIN WITH REQUIRED
# ============================================================================

subtest 'full chain: namespace -> permitted -> skip -> required' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'order.customer' => 'John',
        'order.items[0].product' => 'Widget',
        'order.items[0]._destroy' => 0,
        'order.secret' => 'hidden',
    });

    my $data = $sp
        ->namespace('order')
        ->permitted('customer', +{items => ['product', '_destroy']})
        ->skip('_destroy')
        ->required('customer')
        ->to_hash;

    is $data->{customer}, 'John', 'customer present';
    ok !exists $data->{secret}, 'secret excluded by permitted';
    ok !exists $data->{items}[0]{_destroy}, '_destroy removed by skip';
};

subtest 'full chain with required fails when required field missing' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'order.items[0].product' => 'Widget',
    });

    my $err = dies {
        $sp->namespace('order')
           ->permitted('customer', +{items => ['product']})
           ->required('customer')
           ->to_hash;
    };

    like $err, qr/customer/, 'Error mentions missing required field';
};

# ============================================================================
# NO REQUIRED = NO VALIDATION
# ============================================================================

subtest 'without required() - no validation happens' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        optional => 'value',
    });
    my $data = $sp->to_hash;
    is $data, { optional => 'value' }, 'No required = no validation';
};

done_testing;
