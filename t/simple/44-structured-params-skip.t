#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;

use lib 'lib';
use PAGI::Simple::StructuredParams;

# ============================================================================
# BASIC SKIP FUNCTIONALITY
# ============================================================================

subtest 'skip() removes items where field is truthy' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'items[0].name' => 'Keep Me',
        'items[0]._destroy' => 0,
        'items[1].name' => 'Delete Me',
        'items[1]._destroy' => 1,
        'items[2].name' => 'Also Keep',
    });

    my $result = $sp->skip('_destroy')->to_hash;

    is scalar(@{$result->{items}}), 2, 'one item removed';
    is $result->{items}[0]{name}, 'Keep Me', 'first kept item';
    is $result->{items}[1]{name}, 'Also Keep', 'second kept item';
};

subtest 'skip() removes _destroy field from surviving items' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'items[0].name' => 'Keep Me',
        'items[0]._destroy' => 0,
        'items[0].other' => 'data',
    });

    my $result = $sp->skip('_destroy')->to_hash;

    ok !exists $result->{items}[0]{_destroy}, '_destroy field removed';
    is $result->{items}[0]{name}, 'Keep Me', 'name preserved';
    is $result->{items}[0]{other}, 'data', 'other field preserved';
};

subtest 'skip() treats truthy values correctly' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'items[0].name' => 'Zero',
        'items[0]._destroy' => 0,
        'items[1].name' => 'Empty String',
        'items[1]._destroy' => '',
        'items[2].name' => 'One',
        'items[2]._destroy' => 1,
        'items[3].name' => 'True String',
        'items[3]._destroy' => 'yes',
    });

    my $result = $sp->skip('_destroy')->to_hash;

    is scalar(@{$result->{items}}), 2, 'two items kept (falsy _destroy)';
    is $result->{items}[0]{name}, 'Zero', '0 is falsy';
    is $result->{items}[1]{name}, 'Empty String', 'empty string is falsy';
};

# ============================================================================
# MULTIPLE SKIP FIELDS
# ============================================================================

subtest 'skip() with multiple fields' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'items[0].name' => 'Keep',
        'items[1].name' => 'Delete via _destroy',
        'items[1]._destroy' => 1,
        'items[2].name' => 'Delete via _remove',
        'items[2]._remove' => 1,
        'items[3].name' => 'Also Keep',
        'items[3]._destroy' => 0,
        'items[3]._remove' => 0,
    });

    my $result = $sp->skip('_destroy', '_remove')->to_hash;

    is scalar(@{$result->{items}}), 2, 'two items removed';
    is $result->{items}[0]{name}, 'Keep', 'first kept';
    is $result->{items}[1]{name}, 'Also Keep', 'second kept';
    ok !exists $result->{items}[1]{_destroy}, '_destroy removed from kept item';
    ok !exists $result->{items}[1]{_remove}, '_remove removed from kept item';
};

# ============================================================================
# NESTED STRUCTURES
# ============================================================================

subtest 'skip() works on nested arrays' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'order.line_items[0].product' => 'Widget',
        'order.line_items[0]._destroy' => 0,
        'order.line_items[1].product' => 'Gadget',
        'order.line_items[1]._destroy' => 1,
        'order.customer' => 'John',
    });

    my $result = $sp->skip('_destroy')->to_hash;

    is $result->{order}{customer}, 'John', 'scalar preserved';
    is scalar(@{$result->{order}{line_items}}), 1, 'one item kept';
    is $result->{order}{line_items}[0]{product}, 'Widget', 'kept item correct';
    ok !exists $result->{order}{line_items}[0]{_destroy}, '_destroy removed';
};

subtest 'skip() works on deeply nested arrays' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'data.level1.items[0].name' => 'Keep',
        'data.level1.items[0]._destroy' => 0,
        'data.level1.items[1].name' => 'Remove',
        'data.level1.items[1]._destroy' => 1,
    });

    my $result = $sp->skip('_destroy')->to_hash;

    is scalar(@{$result->{data}{level1}{items}}), 1, 'deeply nested filter works';
    is $result->{data}{level1}{items}[0]{name}, 'Keep', 'correct item kept';
};

# ============================================================================
# WITH PERMITTED
# ============================================================================

subtest 'skip() works with permitted()' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'items[0].name' => 'Keep',
        'items[0].secret' => 'hidden',
        'items[0]._destroy' => 0,
        'items[1].name' => 'Remove',
        'items[1].secret' => 'also hidden',
        'items[1]._destroy' => 1,
    });

    my $result = $sp
        ->permitted(+{ items => ['name', '_destroy'] })
        ->skip('_destroy')
        ->to_hash;

    is scalar(@{$result->{items}}), 1, 'skip applied after permitted';
    is $result->{items}[0]{name}, 'Keep', 'permitted field kept';
    ok !exists $result->{items}[0]{secret}, 'unpermitted field excluded';
    ok !exists $result->{items}[0]{_destroy}, '_destroy removed';
};

subtest 'skip() with namespace and permitted' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'order.items[0].product' => 'Widget',
        'order.items[0]._destroy' => 0,
        'order.items[1].product' => 'Gadget',
        'order.items[1]._destroy' => 1,
        'order.customer' => 'John',
    });

    my $result = $sp
        ->namespace('order')
        ->permitted('customer', +{ items => ['product', '_destroy'] })
        ->skip('_destroy')
        ->to_hash;

    is $result->{customer}, 'John', 'scalar with namespace';
    is scalar(@{$result->{items}}), 1, 'skip worked with namespace';
    is $result->{items}[0]{product}, 'Widget', 'kept item correct';
};

# ============================================================================
# EDGE CASES
# ============================================================================

subtest 'skip() with no arrays is no-op' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        name => 'John',
        email => 'john@example.com',
    });

    my $result = $sp->skip('_destroy')->to_hash;

    is $result, { name => 'John', email => 'john@example.com' }, 'scalars pass through';
};

subtest 'skip() with empty array' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        name => 'Test',
    });

    # Manually construct with empty array for this edge case
    my $result = $sp->skip('_destroy')->to_hash;
    is $result, { name => 'Test' }, 'no items field when not in input';
};

subtest 'skip() all items removed results in empty array' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'items[0].name' => 'Delete 1',
        'items[0]._destroy' => 1,
        'items[1].name' => 'Delete 2',
        'items[1]._destroy' => 1,
    });

    my $result = $sp->skip('_destroy')->to_hash;

    is $result->{items}, [], 'empty array when all items skipped';
};

subtest 'skip() without calling skip() returns all data' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'items[0].name' => 'Item',
        'items[0]._destroy' => 1,
    });

    my $result = $sp->to_hash;

    is $result->{items}[0]{_destroy}, 1, '_destroy preserved when skip not called';
    is $result->{items}[0]{name}, 'Item', 'item preserved';
};

subtest 'skip() with array of scalars' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'tags[0]' => 'perl',
        'tags[1]' => 'web',
    });

    my $result = $sp->skip('_destroy')->to_hash;

    is $result->{tags}, ['perl', 'web'], 'scalar arrays pass through skip';
};

done_testing;
