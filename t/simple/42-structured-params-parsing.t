#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Hash::MultiValue;

use lib 'lib';
use PAGI::Simple::StructuredParams;

# ============================================================================
# PARSE KEY TESTS
# ============================================================================

subtest '_parse_key() simple keys' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {});

    is [$sp->_parse_key('name')], ['name'], 'simple key';
    is [$sp->_parse_key('a')], ['a'], 'single char key';
};

subtest '_parse_key() dot notation' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {});

    is [$sp->_parse_key('person.name')], ['person', 'name'], 'two-level dot';
    is [$sp->_parse_key('a.b.c')], ['a', 'b', 'c'], 'three-level dot';
    is [$sp->_parse_key('a.b.c.d')], ['a', 'b', 'c', 'd'], 'four-level dot';
};

subtest '_parse_key() bracket notation' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {});

    is [$sp->_parse_key('items[0]')], ['items', '[0]'], 'array index';
    is [$sp->_parse_key('items[10]')], ['items', '[10]'], 'two-digit index';
    is [$sp->_parse_key('items[0].name')], ['items', '[0]', 'name'], 'array with field';
    is [$sp->_parse_key('items[0][1]')], ['items', '[0]', '[1]'], 'nested arrays';
};

subtest '_parse_key() empty brackets (D2)' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {});

    is [$sp->_parse_key('items[]')], ['items', '[]'], 'empty bracket';
    is [$sp->_parse_key('items[].name')], ['items', '[]', 'name'], 'empty bracket with field';
};

subtest '_parse_key() mixed notation' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {});

    is [$sp->_parse_key('order.items[0].product.name')],
              ['order', 'items', '[0]', 'product', 'name'],
              'complex mixed notation';
};

# ============================================================================
# APPLY NAMESPACE TESTS
# ============================================================================

subtest '_apply_namespace() no namespace' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => { name => 'John', age => 30 });
    my $filtered = $sp->_apply_namespace();

    isa_ok $filtered, 'Hash::MultiValue';
    is $filtered->get('name'), 'John', 'name preserved';
    is $filtered->get('age'), 30, 'age preserved';
};

subtest '_apply_namespace() with namespace' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'my_app.name' => 'John',
        'my_app.email' => 'john@example.com',
        'other.field' => 'ignored',
    });
    $sp->namespace('my_app');

    my $filtered = $sp->_apply_namespace();
    is $filtered->get('name'), 'John', 'namespaced key stripped';
    is $filtered->get('email'), 'john@example.com', 'email stripped';
    ok !$filtered->get('other.field'), 'non-matching key excluded';
    ok !$filtered->get('field'), 'other.field not rewritten';
};

subtest '_apply_namespace() preserves duplicates' => sub {
    my $mv = Hash::MultiValue->new(
        'ns.tag' => 'a',
        'ns.tag' => 'b',
        'ns.tag' => 'c',
    );
    my $sp = PAGI::Simple::StructuredParams->new(multi_value => $mv);
    $sp->namespace('ns');

    my $filtered = $sp->_apply_namespace();
    my @values = $filtered->get_all('tag');
    is \@values, ['a', 'b', 'c'], 'duplicate values preserved';
};

# ============================================================================
# BUILD NESTED - SIMPLE TESTS
# ============================================================================

subtest 'Simple scalar' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => { name => 'John' });
    is $sp->to_hash, { name => 'John' }, 'simple scalar';
};

subtest 'Multiple scalars' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        name => 'John',
        email => 'john@example.com',
    });
    my $result = $sp->to_hash;
    is $result->{name}, 'John', 'name';
    is $result->{email}, 'john@example.com', 'email';
};

# ============================================================================
# BUILD NESTED - DOT NOTATION
# ============================================================================

subtest 'Dot notation nesting' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'person.name' => 'John',
    });
    is $sp->to_hash, { person => { name => 'John' } }, 'nested hash';
};

subtest 'Deep nesting' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'a.b.c.d' => 'val',
    });
    is $sp->to_hash, { a => { b => { c => { d => 'val' } } } }, 'four levels deep';
};

subtest 'Multiple keys same parent' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'person.first' => 'John',
        'person.last' => 'Doe',
    });
    is $sp->to_hash, { person => { first => 'John', last => 'Doe' } },
              'multiple keys merge into same hash';
};

# ============================================================================
# BUILD NESTED - ARRAY NOTATION
# ============================================================================

subtest 'Array at root' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'items[0]' => 'first',
        'items[1]' => 'second',
    });
    is $sp->to_hash, { items => ['first', 'second'] }, 'array of scalars';
};

subtest 'Array of hashes' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'items[0].name' => 'X',
        'items[0].qty' => 2,
    });
    is $sp->to_hash, { items => [{ name => 'X', qty => 2 }] }, 'array of hashes';
};

subtest 'Multiple array items' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'items[0].name' => 'A',
        'items[1].name' => 'B',
    });
    is $sp->to_hash, { items => [{ name => 'A' }, { name => 'B' }] },
              'multiple array items';
};

subtest 'Sparse array (D5)' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'items[1]' => 'val',
    });
    is $sp->to_hash, { items => [undef, 'val'] }, 'sparse array preserves indices';
};

subtest 'Sparse array with gap' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'items[0]' => 'a',
        'items[3]' => 'b',
    });
    my $result = $sp->to_hash;
    is $result, { items => ['a', undef, undef, 'b'] }, 'sparse array with gap';
};

# ============================================================================
# BUILD NESTED - MIXED NOTATION
# ============================================================================

subtest 'Mixed hash and array nesting' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'order.items[0].product.name' => 'Widget',
    });
    is $sp->to_hash,
              { order => { items => [{ product => { name => 'Widget' } }] } },
              'complex nested structure';
};

subtest 'Array then hash fields' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'tags[0]' => 'a',
        'tags[1]' => 'b',
        'name' => 'test',
    });
    my $result = $sp->to_hash;
    is $result->{tags}, ['a', 'b'], 'array field';
    is $result->{name}, 'test', 'scalar field alongside';
};

# ============================================================================
# BUILD NESTED - EMPTY BRACKETS (D2)
# ============================================================================

subtest 'Empty brackets sequential append (D2)' => sub {
    # Need Hash::MultiValue to preserve order of duplicate keys
    my $mv = Hash::MultiValue->new(
        'items[]' => 'a',
        'items[]' => 'b',
    );
    my $sp = PAGI::Simple::StructuredParams->new(multi_value => $mv);
    is $sp->to_hash, { items => ['a', 'b'] }, 'empty brackets assign sequential indices';
};

subtest 'Empty brackets mixed with explicit indices (D2)' => sub {
    my $mv = Hash::MultiValue->new(
        'items[2]' => 'c',
        'items[]' => 'd',
        'items[]' => 'e',
    );
    my $sp = PAGI::Simple::StructuredParams->new(multi_value => $mv);
    # Sorted order: items[2], items[], items[]
    # items[2] sets auto_index to 3, then [] gets 3, [] gets 4
    is $sp->to_hash, { items => [undef, undef, 'c', 'd', 'e'] },
              'empty brackets continue after explicit index';
};

subtest 'Empty brackets in nested context (D2)' => sub {
    my $mv = Hash::MultiValue->new(
        'order.items[].name' => 'X',
        'order.items[].name' => 'Y',
    );
    my $sp = PAGI::Simple::StructuredParams->new(multi_value => $mv);
    is $sp->to_hash,
              { order => { items => [{ name => 'X' }, { name => 'Y' }] } },
              'empty brackets in nested structure';
};

# ============================================================================
# NAMESPACE + PARSING INTEGRATION
# ============================================================================

subtest 'Namespace with nested parsing' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'my_app.person.name' => 'John',
        'my_app.person.age' => 30,
        'other.ignored' => 'xxx',
    });
    $sp->namespace('my_app');

    is $sp->to_hash, { person => { name => 'John', age => 30 } },
              'namespace applied before parsing';
};

subtest 'Namespace with array parsing' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'my_app_model_order.line_items[0].product' => 'Widget',
        'my_app_model_order.line_items[0].qty' => 5,
        'my_app_model_order.customer_name' => 'John',
    });
    $sp->namespace('my_app_model_order');

    my $result = $sp->to_hash;
    is $result->{customer_name}, 'John', 'scalar field';
    is $result->{line_items}, [{ product => 'Widget', qty => 5 }], 'array field';
};

# ============================================================================
# EDGE CASES
# ============================================================================

subtest 'Empty params' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {});
    is $sp->to_hash, {}, 'empty params yields empty hash';
};

subtest 'Numeric string values' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'count' => '42',
        'price' => '19.99',
    });
    my $result = $sp->to_hash;
    is $result->{count}, '42', 'numeric string preserved';
    is $result->{price}, '19.99', 'decimal string preserved';
};

subtest 'Empty string value' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'name' => '',
    });
    is $sp->to_hash, { name => '' }, 'empty string preserved';
};

subtest 'Undef value' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {
        'name' => undef,
    });
    is $sp->to_hash, { name => undef }, 'undef preserved';
};

done_testing;
