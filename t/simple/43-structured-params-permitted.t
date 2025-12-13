#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Hash::MultiValue;

use lib 'lib';
use PAGI::Simple::StructuredParams;

# ============================================================================
# SIMPLE SCALAR PERMITTED
# ============================================================================

subtest 'permitted() single scalar field' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        name => 'John',
        email => 'john@example.com',
        password => 'secret',
    });

    my $result = $sp->permitted('name')->to_hash;
    is $result, { name => 'John' }, 'only permitted field returned';
    ok !exists $result->{email}, 'unpermitted email excluded';
    ok !exists $result->{password}, 'unpermitted password excluded';
};

subtest 'permitted() multiple scalar fields' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        name => 'John',
        email => 'john@example.com',
        password => 'secret',
    });

    my $result = $sp->permitted('name', 'email')->to_hash;
    is $result, { name => 'John', email => 'john@example.com' }, 'multiple fields permitted';
    ok !exists $result->{password}, 'unpermitted field excluded';
};

subtest 'permitted() missing field is not included' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        name => 'John',
    });

    my $result = $sp->permitted('name', 'email')->to_hash;
    is $result, { name => 'John' }, 'only present fields included';
    ok !exists $result->{email}, 'missing field not in result';
};

# ============================================================================
# NESTED HASH RULES
# ============================================================================

subtest 'permitted() nested hash' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'person.name' => 'John',
        'person.age' => 30,
        'person.ssn' => '123-45-6789',
    });

    my $result = $sp->permitted('person', ['name', 'age'])->to_hash;
    is $result, { person => { name => 'John', age => 30 } }, 'nested hash filtered';
    ok !exists $result->{person}{ssn}, 'unpermitted nested field excluded';
};

subtest 'permitted() deeply nested hash' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'user.profile.name' => 'John',
        'user.profile.bio' => 'Developer',
        'user.profile.secret' => 'hidden',
        'user.email' => 'john@example.com',
    });

    my $result = $sp->permitted(
        'user', ['email', 'profile', ['name', 'bio']]
    )->to_hash;

    is $result->{user}{email}, 'john@example.com', 'first level field';
    is $result->{user}{profile}{name}, 'John', 'nested field';
    is $result->{user}{profile}{bio}, 'Developer', 'nested field 2';
    ok !exists $result->{user}{profile}{secret}, 'unpermitted nested field excluded';
};

# ============================================================================
# ARRAY OF SCALARS (D1 DUPLICATE HANDLING)
# ============================================================================

subtest 'permitted() array of scalars with +{field => []}' => sub {
    my $mv = Hash::MultiValue->new(
        tags => 'perl',
        tags => 'web',
        tags => 'async',
        name => 'Project',
    );
    my $sp = PAGI::Simple::StructuredParams->new(multi_value => $mv);

    my $result = $sp->permitted('name', +{ tags => [] })->to_hash;
    is $result->{name}, 'Project', 'scalar field';
    is $result->{tags}, ['perl', 'web', 'async'], 'D1: all duplicate values preserved';
};

subtest 'permitted() array of scalars - single value' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        tags => 'only-one',
    });

    my $result = $sp->permitted(+{ tags => [] })->to_hash;
    is $result->{tags}, ['only-one'], 'single value becomes array';
};

subtest 'permitted() array of scalars - empty' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        name => 'Test',
    });

    my $result = $sp->permitted('name', +{ tags => [] })->to_hash;
    is $result, { name => 'Test' }, 'missing array field not included';
    ok !exists $result->{tags}, 'empty array not in result';
};

# ============================================================================
# ARRAY OF HASHES
# ============================================================================

subtest 'permitted() array of hashes' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'items[0].product' => 'Widget',
        'items[0].qty' => 5,
        'items[0].secret' => 'hidden',
        'items[1].product' => 'Gadget',
        'items[1].qty' => 3,
    });

    my $result = $sp->permitted(+{ items => ['product', 'qty'] })->to_hash;
    is $result->{items}, [
        { product => 'Widget', qty => 5 },
        { product => 'Gadget', qty => 3 },
    ], 'array of hashes filtered';
};

subtest 'permitted() array of hashes - nested' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'items[0].product.name' => 'Widget',
        'items[0].product.sku' => 'W123',
        'items[0].product.cost' => 100,  # unpermitted
        'items[0].qty' => 5,
    });

    my $result = $sp->permitted(+{ items => ['qty', 'product', ['name', 'sku']] })->to_hash;
    is $result->{items}[0]{qty}, 5, 'scalar in array item';
    is $result->{items}[0]{product}{name}, 'Widget', 'nested hash in array item';
    is $result->{items}[0]{product}{sku}, 'W123', 'nested hash field 2';
    ok !exists $result->{items}[0]{product}{cost}, 'unpermitted nested field excluded';
};

# ============================================================================
# MIXED RULES
# ============================================================================

subtest 'permitted() mixed scalar, nested, and array rules' => sub {
    my $mv = Hash::MultiValue->new(
        'customer_name' => 'John Doe',
        'customer_email' => 'john@example.com',
        'notes' => 'Rush order',
        'secret' => 'hidden',
        'tags' => 'urgent',
        'tags' => 'wholesale',
        'line_items[0].product' => 'Widget',
        'line_items[0].quantity' => 10,
        'line_items[0].price' => 9.99,  # unpermitted
        'line_items[1].product' => 'Gadget',
        'line_items[1].quantity' => 5,
    );
    my $sp = PAGI::Simple::StructuredParams->new(multi_value => $mv);

    my $result = $sp->permitted(
        'customer_name',
        'customer_email',
        'notes',
        +{ tags => [] },
        +{ line_items => ['product', 'quantity'] },
    )->to_hash;

    is $result->{customer_name}, 'John Doe', 'scalar 1';
    is $result->{customer_email}, 'john@example.com', 'scalar 2';
    is $result->{notes}, 'Rush order', 'scalar 3';
    ok !exists $result->{secret}, 'unpermitted scalar excluded';
    is $result->{tags}, ['urgent', 'wholesale'], 'D1 array of scalars';
    is $result->{line_items}, [
        { product => 'Widget', quantity => 10 },
        { product => 'Gadget', quantity => 5 },
    ], 'array of hashes filtered';
};

# ============================================================================
# WITH NAMESPACE
# ============================================================================

subtest 'permitted() with namespace' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'my_app_order.customer_name' => 'John',
        'my_app_order.customer_email' => 'john@example.com',
        'my_app_order.admin_notes' => 'secret',
        'other.field' => 'ignored',
    });

    my $result = $sp
        ->namespace('my_app_order')
        ->permitted('customer_name', 'customer_email')
        ->to_hash;

    is $result, {
        customer_name => 'John',
        customer_email => 'john@example.com',
    }, 'namespace + permitted work together';
};

subtest 'permitted() with namespace and array of hashes' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'order.line_items[0].product' => 'Widget',
        'order.line_items[0].qty' => 5,
        'order.line_items[0].cost' => 100,
        'order.customer' => 'John',
    });

    my $result = $sp
        ->namespace('order')
        ->permitted('customer', +{ line_items => ['product', 'qty'] })
        ->to_hash;

    is $result->{customer}, 'John', 'scalar with namespace';
    is $result->{line_items}, [{ product => 'Widget', qty => 5 }], 'array with namespace';
    ok !exists $result->{line_items}[0]{cost}, 'unpermitted field in array excluded';
};

# ============================================================================
# EDGE CASES
# ============================================================================

subtest 'permitted() with no args same as not calling it' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        name => 'John',
        email => 'john@example.com',
    });

    # Call permitted with no args - same as not calling it
    my $result = $sp->permitted()->to_hash;
    is $result, { name => 'John', email => 'john@example.com' }, 'no args = all data';
};

subtest 'permitted() empty data' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {});

    my $result = $sp->permitted('name', 'email')->to_hash;
    is $result, {}, 'empty input = empty output';
};

subtest 'permitted() sparse array preserved' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'items[0].name' => 'First',
        'items[2].name' => 'Third',  # index 1 is missing
    });

    my $result = $sp->permitted(+{ items => ['name'] })->to_hash;
    is scalar(@{$result->{items}}), 3, 'sparse array length preserved';
    is $result->{items}[0]{name}, 'First', 'index 0';
    is $result->{items}[2]{name}, 'Third', 'index 2';
};

subtest 'without permitted() returns all data' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        name => 'John',
        email => 'john@example.com',
    });

    # Don't call permitted() at all
    my $result = $sp->to_hash;
    is $result, { name => 'John', email => 'john@example.com' }, 'no permitted = all data';
};

done_testing;
