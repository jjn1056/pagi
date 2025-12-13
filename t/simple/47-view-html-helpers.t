#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;

use lib 'lib';

# ============================================================================
# DIRECT HELPER FUNCTION TESTS
# ============================================================================

# Test the helper functions directly (without template rendering)
require PAGI::Simple::View::Helpers::Html;
pass 'PAGI::Simple::View::Helpers::Html loaded';

# Import helper functions for testing
my $helpers = PAGI::Simple::View::Helpers::Html::get_helpers();

# ============================================================================
# BOOLEAN ATTRIBUTE HELPERS
# ============================================================================

subtest 'checked_if' => sub {
    my $checked_if = $helpers->{checked_if};

    is $checked_if->(1), 'checked', 'true returns checked';
    is $checked_if->(0), '', 'false returns empty string';
    is $checked_if->(undef), '', 'undef returns empty string';
    is $checked_if->('yes'), 'checked', 'truthy string returns checked';
    is $checked_if->(''), '', 'empty string returns empty string';
};

subtest 'disabled_if' => sub {
    my $disabled_if = $helpers->{disabled_if};

    is $disabled_if->(1), 'disabled', 'true returns disabled';
    is $disabled_if->(0), '', 'false returns empty string';
    is $disabled_if->(undef), '', 'undef returns empty string';
};

subtest 'selected_if' => sub {
    my $selected_if = $helpers->{selected_if};

    is $selected_if->(1), 'selected', 'true returns selected';
    is $selected_if->(0), '', 'false returns empty string';
    is $selected_if->('active' eq 'active'), 'selected', 'expression true returns selected';
    is $selected_if->('active' eq 'inactive'), '', 'expression false returns empty';
};

subtest 'readonly_if' => sub {
    my $readonly_if = $helpers->{readonly_if};

    is $readonly_if->(1), 'readonly', 'true returns readonly';
    is $readonly_if->(0), '', 'false returns empty string';
};

subtest 'required_if' => sub {
    my $required_if = $helpers->{required_if};

    is $required_if->(1), 'required', 'true returns required';
    is $required_if->(0), '', 'false returns empty string';
};

subtest 'bool_attr generic' => sub {
    my $bool_attr = $helpers->{bool_attr};

    is $bool_attr->('autofocus', 1), 'autofocus', 'true returns attribute name';
    is $bool_attr->('autofocus', 0), '', 'false returns empty string';
    is $bool_attr->('multiple', 1), 'multiple', 'works with any attribute';
    is $bool_attr->('async', 'yes'), 'async', 'truthy value returns attribute';
};

# ============================================================================
# CSS CLASS HELPERS
# ============================================================================

subtest 'class_if' => sub {
    my $class_if = $helpers->{class_if};

    is $class_if->('active', 1), 'active', 'true returns class name';
    is $class_if->('active', 0), '', 'false returns empty string';
    is $class_if->('highlighted', 'yes'), 'highlighted', 'truthy returns class';
    is $class_if->('error', undef), '', 'undef returns empty string';
};

subtest 'active_class' => sub {
    my $active_class = $helpers->{active_class};

    # Default class is 'selected'
    is $active_class->('home', 'home'), 'selected', 'matching values return selected';
    is $active_class->('home', 'about'), '', 'non-matching values return empty';
    is $active_class->('active', 'active'), 'selected', 'active matches active';

    # Custom class name
    is $active_class->('home', 'home', 'current'), 'current', 'custom class returned when matching';
    is $active_class->('home', 'about', 'current'), '', 'custom class not returned when not matching';
    is $active_class->('tab1', 'tab1', 'active-tab'), 'active-tab', 'works with any class name';
};

subtest 'classes' => sub {
    my $classes = $helpers->{classes};

    # Simple string
    is $classes->('btn'), 'btn', 'single string returns as-is';

    # Multiple strings
    is $classes->('btn', 'primary'), 'btn primary', 'multiple strings joined';

    # Conditional classes
    is $classes->('btn', ['primary', 1]), 'btn primary', 'conditional true included';
    is $classes->('btn', ['primary', 0]), 'btn', 'conditional false excluded';

    # Mixed
    is $classes->('btn', ['primary', 1], ['disabled', 0]), 'btn primary',
        'mixed conditions: include true, exclude false';
    is $classes->('btn', ['primary', 1], ['large', 1]), 'btn primary large',
        'multiple true conditions';
    is $classes->('btn', ['primary', 0], ['large', 0]), 'btn',
        'multiple false conditions';

    # Complex case
    is $classes->('card', 'card-body', ['card-active', 1], ['card-error', 0]),
        'card card-body card-active',
        'complex mixed case';

    # Empty/undef handling
    is $classes->('btn', undef, ['active', 1]), 'btn active', 'undef in strings ignored';
    is $classes->('btn', '', ['active', 1]), 'btn active', 'empty string in strings ignored';

    # All conditional false
    is $classes->(['hidden', 0], ['disabled', 0]), '', 'all false returns empty';

    # All conditional true
    is $classes->(['a', 1], ['b', 1], ['c', 1]), 'a b c', 'all true returns all';
};

# ============================================================================
# INTEGRATION WITH VIEW (TEMPLATE RENDERING)
# ============================================================================

subtest 'Helpers available in templates' => sub {
    require PAGI::Simple::View;

    my $view = PAGI::Simple::View->new(
        template_dir => 't/templates',
        cache        => 0,
    );

    # Test checked_if in template
    my $html = $view->render_string(
        '<input type="checkbox" <%= checked_if($v->completed) %>>',
        completed => 1
    );
    like $html, qr/checked/, 'checked_if works in template (true)';

    $html = $view->render_string(
        '<input type="checkbox" <%= checked_if($v->completed) %>>',
        completed => 0
    );
    unlike $html, qr/checked/, 'checked_if works in template (false)';

    # Test disabled_if in template
    $html = $view->render_string(
        '<input type="text" <%= disabled_if($v->readonly) %>>',
        readonly => 1
    );
    like $html, qr/disabled/, 'disabled_if works in template';

    # Test class_if in template
    $html = $view->render_string(
        '<div class="<%= class_if(\'active\', $v->is_active) %>">',
        is_active => 1
    );
    like $html, qr/class="active"/, 'class_if works in template (true)';

    $html = $view->render_string(
        '<div class="<%= class_if(\'active\', $v->is_active) %>">',
        is_active => 0
    );
    like $html, qr/class=""/, 'class_if works in template (false)';

    # Test active_class in template
    $html = $view->render_string(
        '<a class="<%= active_class($v->filter, \'home\') %>">All</a>',
        filter => 'home'
    );
    like $html, qr/class="selected"/, 'active_class works when matching';

    $html = $view->render_string(
        '<a class="<%= active_class($v->filter, \'home\') %>">All</a>',
        filter => 'active'
    );
    like $html, qr/class=""/, 'active_class works when not matching';

    # Test classes in template
    $html = $view->render_string(
        '<button class="<%= classes(\'btn\', [\'primary\', $v->is_primary], [\'disabled\', $v->is_disabled]) %>">',
        is_primary => 1,
        is_disabled => 0
    );
    like $html, qr/class="btn primary"/, 'classes works with conditions';
};

# ============================================================================
# REAL-WORLD USAGE PATTERNS
# ============================================================================

subtest 'Todo item checkbox pattern' => sub {
    my $view = PAGI::Simple::View->new(
        template_dir => 't/templates',
        cache        => 0,
    );

    # Simulated todo item - completed
    my $html = $view->render_string(<<'TEMPLATE', completed => 1, title => 'Buy milk');
<li class="todo-item <%= class_if('completed', $v->completed) %>">
  <input type="checkbox" <%= checked_if($v->completed) %>>
  <span><%= $v->title %></span>
</li>
TEMPLATE

    like $html, qr/class="todo-item completed"/, 'completed class applied';
    like $html, qr/<input type="checkbox" checked>/, 'checkbox is checked';

    # Simulated todo item - not completed
    $html = $view->render_string(<<'TEMPLATE', completed => 0, title => 'Call mom');
<li class="todo-item <%= class_if('completed', $v->completed) %>">
  <input type="checkbox" <%= checked_if($v->completed) %>>
  <span><%= $v->title %></span>
</li>
TEMPLATE

    like $html, qr/class="todo-item "/, 'no completed class when not completed';
    like $html, qr/<input type="checkbox" >/, 'checkbox is not checked';
};

subtest 'Navigation filter pattern' => sub {
    my $view = PAGI::Simple::View->new(
        template_dir => 't/templates',
        cache        => 0,
    );

    my $html = $view->render_string(<<'TEMPLATE', filter => 'active');
<nav>
  <a class="<%= active_class($v->filter, 'home') %>">All</a>
  <a class="<%= active_class($v->filter, 'active') %>">Active</a>
  <a class="<%= active_class($v->filter, 'completed') %>">Completed</a>
</nav>
TEMPLATE

    # All link should have empty class (filter is 'active', not 'home')
    like $html, qr/class="">All/, 'All link has empty class';
    # Active link should have selected class
    like $html, qr/class="selected">Active/, 'Active is selected';
    # Completed link should have empty class
    like $html, qr/class="">Completed/, 'Completed has empty class';
};

done_testing;
