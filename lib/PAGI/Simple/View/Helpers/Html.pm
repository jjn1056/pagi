package PAGI::Simple::View::Helpers::Html;

use strict;
use warnings;
use experimental 'signatures';

our $VERSION = '0.01';

=head1 NAME

PAGI::Simple::View::Helpers::Html - HTML attribute helpers for PAGI::Simple templates

=head1 SYNOPSIS

    # Boolean attributes in templates:
    <input type="checkbox" <%= checked_if($todo->completed) %>>
    <input type="text" <%= disabled_if($readonly) %>>
    <option <%= selected_if($current eq $value) %>>

    # Conditional CSS classes:
    <a class="<%= class_if('active', $is_active) %>">Link</a>
    <a class="<%= active_class($filter, 'home') %>">All</a>
    <div class="<%= classes('btn', ['primary', $is_primary], ['disabled', $is_disabled]) %>">

=head1 DESCRIPTION

This module provides template helpers for generating conditional HTML attributes
and CSS classes. The helpers eliminate repetitive ternary expressions in templates.

=head1 FUNCTIONS

=cut

=head2 get_helpers

    my $helpers = PAGI::Simple::View::Helpers::Html::get_helpers($view);

Returns a hashref of all HTML helper functions for use in templates.
This is called internally by PAGI::Simple::View.

=cut

sub get_helpers ($view = undef) {
    return {
        # Boolean attribute helpers
        checked_if   => \&checked_if,
        disabled_if  => \&disabled_if,
        selected_if  => \&selected_if,
        readonly_if  => \&readonly_if,
        required_if  => \&required_if,
        bool_attr    => \&bool_attr,

        # CSS class helpers
        class_if     => \&class_if,
        active_class => \&active_class,
        classes      => \&classes,
    };
}

=head1 BOOLEAN ATTRIBUTE HELPERS

These helpers generate HTML boolean attributes based on a condition.
They return the attribute name if the condition is true, or an empty string if false.

=head2 checked_if

    <input type="checkbox" <%= checked_if($todo->completed) %>>

Returns 'checked' if condition is true, empty string otherwise.

=cut

sub checked_if ($condition) {
    return $condition ? 'checked' : '';
}

=head2 disabled_if

    <input type="text" <%= disabled_if($is_readonly) %>>

Returns 'disabled' if condition is true, empty string otherwise.

=cut

sub disabled_if ($condition) {
    return $condition ? 'disabled' : '';
}

=head2 selected_if

    <option <%= selected_if($current eq 'home') %>>All</option>

Returns 'selected' if condition is true, empty string otherwise.

=cut

sub selected_if ($condition) {
    return $condition ? 'selected' : '';
}

=head2 readonly_if

    <input type="text" <%= readonly_if($locked) %>>

Returns 'readonly' if condition is true, empty string otherwise.

=cut

sub readonly_if ($condition) {
    return $condition ? 'readonly' : '';
}

=head2 required_if

    <input type="email" <%= required_if($mandatory) %>>

Returns 'required' if condition is true, empty string otherwise.

=cut

sub required_if ($condition) {
    return $condition ? 'required' : '';
}

=head2 bool_attr

    <input <%= bool_attr('autofocus', $should_focus) %>>

Generic helper for any boolean attribute. Returns the attribute name
if condition is true, empty string otherwise.

=cut

sub bool_attr ($attr_name, $condition) {
    return $condition ? $attr_name : '';
}

=head1 CSS CLASS HELPERS

These helpers generate conditional CSS class names for use in class attributes.

=head2 class_if

    <div class="<%= class_if('active', $is_active) %>">

Returns the class name if condition is true, empty string otherwise.

=cut

sub class_if ($class_name, $condition) {
    return $condition ? $class_name : '';
}

=head2 active_class

    <a class="<%= active_class($filter, 'home') %>">All</a>
    <a class="<%= active_class($filter, 'home', 'current') %>">All</a>

Navigation helper. Returns the class name if C<$current> equals C<$check>.
Default class name is 'selected'.

=cut

sub active_class ($current, $check, $class = 'selected') {
    return $current eq $check ? $class : '';
}

=head2 classes

    <div class="<%= classes('btn', ['primary', $is_primary], ['disabled', $is_disabled]) %>">

Build a class string from multiple conditional classes.
Accepts a mix of:

=over 4

=item * Strings - always included

=item * Arrayrefs C<[$class, $condition]> - included only if condition is true

=back

Returns the classes joined by spaces.

Example:

    classes('btn', ['primary', 1], ['disabled', 0])
    # Returns: "btn primary"

    classes('card', ['card-active', $is_active], ['card-error', $has_error])
    # Returns: "card card-active" if $is_active is true and $has_error is false

=cut

sub classes (@specs) {
    my @result;
    for my $spec (@specs) {
        if (ref $spec eq 'ARRAY') {
            my ($class, $condition) = @$spec;
            push @result, $class if $condition;
        } else {
            # Plain string - always include (unless undef/empty)
            push @result, $spec if defined $spec && $spec ne '';
        }
    }
    return join(' ', @result);
}

=head1 EXAMPLES

=head2 Todo Item with Checkbox

Before:

    <%
      my $checked = $todo->completed ? 'checked' : '';
      my $completed_class = $todo->completed ? 'completed' : '';
    %>
    <li class="todo-item <%= $completed_class %>">
      <input type="checkbox" <%= $checked %>>
    </li>

After:

    <li class="todo-item <%= class_if('completed', $todo->completed) %>">
      <input type="checkbox" <%= checked_if($todo->completed) %>>
    </li>

=head2 Navigation Filter

Before:

    <%
      my $home_class = $filter eq 'home' ? 'selected' : '';
      my $active_class = $filter eq 'active' ? 'selected' : '';
      my $completed_class = $filter eq 'completed' ? 'selected' : '';
    %>
    <a class="<%= $home_class %>">All</a>
    <a class="<%= $active_class %>">Active</a>
    <a class="<%= $completed_class %>">Completed</a>

After:

    <a class="<%= active_class($filter, 'home') %>">All</a>
    <a class="<%= active_class($filter, 'active') %>">Active</a>
    <a class="<%= active_class($filter, 'completed') %>">Completed</a>

=head2 Button with Multiple Conditional Classes

    <button class="<%= classes('btn', ['btn-primary', $is_primary], ['btn-large', $is_large], ['disabled', !$can_submit]) %>">
      Submit
    </button>

=head1 SEE ALSO

L<PAGI::Simple::View>, L<PAGI::Simple::View::Helpers::Htmx>

=head1 AUTHOR

PAGI Contributors

=cut

1;
