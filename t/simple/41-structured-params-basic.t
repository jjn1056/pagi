#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Hash::MultiValue;

use lib 'lib';
use PAGI::Simple::StructuredParams;

# ============================================================================
# CONSTRUCTOR TESTS
# ============================================================================

subtest 'Basic constructor' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {});
    isa_ok $sp, 'PAGI::Simple::StructuredParams';
};

subtest 'Constructor with params hashref' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => { name => 'John' });
    isa_ok $sp, 'PAGI::Simple::StructuredParams';
};

subtest 'Constructor with source_type' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(
        params => {},
        source_type => 'query'
    );
    isa_ok $sp, 'PAGI::Simple::StructuredParams';
};

subtest 'Constructor with Hash::MultiValue' => sub {
    my $mv = Hash::MultiValue->new(name => 'John', age => '30');
    my $sp = PAGI::Simple::StructuredParams->new(multi_value => $mv);
    isa_ok $sp, 'PAGI::Simple::StructuredParams';
};

subtest 'Constructor with context' => sub {
    my $mock_context = bless {}, 'MockContext';
    my $sp = PAGI::Simple::StructuredParams->new(
        params => {},
        context => $mock_context
    );
    isa_ok $sp, 'PAGI::Simple::StructuredParams';
};

subtest 'Constructor with no args' => sub {
    my $sp = PAGI::Simple::StructuredParams->new();
    isa_ok $sp, 'PAGI::Simple::StructuredParams';
};

# ============================================================================
# CHAINABLE API TESTS
# ============================================================================

subtest 'namespace() returns self for chaining' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {});
    my $result = $sp->namespace('my_app');
    is $result, $sp, 'namespace() returns $self';
};

subtest 'namespace() stores the value' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {});
    $sp->namespace('my_app_model');
    is $sp->namespace(), 'my_app_model', 'namespace() getter returns stored value';
};

# ============================================================================
# NAMESPACE_FOR TESTS
# ============================================================================

# Mock class that simulates Valiant::Naming behavior
{
    package MockValiant::Name;
    sub new { my ($class, $key) = @_; bless { param_key => $key }, $class }
    sub param_key { shift->{param_key} }

    package TestApp::Model::Order;
    sub model_name { MockValiant::Name->new('testapp_model_order') }

    package TestApp::Entity::User;
    sub model_name { MockValiant::Name->new('testapp_entity_user') }

    package NoValiantClass;
    # No model_name method - simulates class without Valiant::Naming
}

subtest 'namespace_for() with class name' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {});
    my $result = $sp->namespace_for('TestApp::Model::Order');

    is $result, $sp, 'namespace_for() returns $self for chaining';
    is $sp->namespace(), 'testapp_model_order', 'namespace set from class model_name->param_key';
};

subtest 'namespace_for() with object instance' => sub {
    my $order = bless {}, 'TestApp::Model::Order';
    my $sp = PAGI::Simple::StructuredParams->new(params => {});
    my $result = $sp->namespace_for($order);

    is $result, $sp, 'namespace_for() returns $self for chaining';
    is $sp->namespace(), 'testapp_model_order', 'namespace set from object class';
};

subtest 'namespace_for() with different class' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {});
    $sp->namespace_for('TestApp::Entity::User');

    is $sp->namespace(), 'testapp_entity_user', 'namespace set correctly for different class';
};

subtest 'namespace_for() with different object' => sub {
    my $user = bless { name => 'John' }, 'TestApp::Entity::User';
    my $sp = PAGI::Simple::StructuredParams->new(params => {});
    $sp->namespace_for($user);

    is $sp->namespace(), 'testapp_entity_user', 'namespace set correctly from different object';
};

subtest 'namespace_for() dies without model_name' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {});

    like(
        dies { $sp->namespace_for('NoValiantClass') },
        qr/NoValiantClass does not provide model_name/,
        'dies with helpful message when class lacks model_name'
    );
};

subtest 'namespace_for() dies for non-existent class' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {});

    # Non-existent classes don't have model_name, so we get the helpful Valiant error
    like(
        dies { $sp->namespace_for('NonExistent::Class::That::Does::Not::Exist') },
        qr/does not provide model_name/,
        'dies when class does not exist or lacks model_name'
    );
};

subtest 'namespace_for() in full chain' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(
        params => { 'testapp_model_order.customer' => 'John' }
    );

    my $result = $sp
        ->namespace_for('TestApp::Model::Order')
        ->permitted('customer')
        ->to_hash;

    is $result, { customer => 'John' }, 'namespace_for() works in full chain';
};

subtest 'namespace_for() with object in full chain' => sub {
    my $order = bless {}, 'TestApp::Model::Order';
    my $sp = PAGI::Simple::StructuredParams->new(
        params => { 'testapp_model_order.total' => '99.99' }
    );

    my $result = $sp
        ->namespace_for($order)
        ->permitted('total')
        ->to_hash;

    is $result, { total => '99.99' }, 'namespace_for() with object works in full chain';
};

subtest 'permitted() returns self for chaining' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {});
    my $result = $sp->permitted('name', 'email');
    is $result, $sp, 'permitted() returns $self';
};

subtest 'permitted() can be called multiple times' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {});
    $sp->permitted('name');
    $sp->permitted('email');
    # Just verify it doesn't die - internal state tested in Step 3
    pass 'Multiple permitted() calls work';
};

subtest 'skip() returns self for chaining' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {});
    my $result = $sp->skip('_destroy');
    is $result, $sp, 'skip() returns $self';
};

subtest 'skip() accepts multiple fields' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => {});
    my $result = $sp->skip('_destroy', '_delete', '_remove');
    is $result, $sp, 'skip() with multiple args returns $self';
};

# ============================================================================
# CHAINING TESTS
# ============================================================================

subtest 'Full chain: namespace -> permitted -> skip' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => { name => 'test' });

    my $result = $sp
        ->namespace('my_app')
        ->permitted('name', 'email')
        ->skip('_destroy');

    is $result, $sp, 'Full chain returns $self';
    is $sp->namespace(), 'my_app', 'namespace was set in chain';
};

subtest 'Chain with to_hash at end' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => { name => 'test' });

    my $hash = $sp
        ->namespace('my_app')
        ->permitted('name')
        ->to_hash;

    is ref($hash), 'HASH', 'to_hash() returns hashref';
};

# ============================================================================
# TO_HASH BASIC TEST
# ============================================================================

subtest 'to_hash() parses simple data' => sub {
    my $sp = PAGI::Simple::StructuredParams->new(params => { name => 'John' });
    my $result = $sp->to_hash;
    is $result, { name => 'John' }, 'to_hash() returns parsed data';
};

done_testing;
