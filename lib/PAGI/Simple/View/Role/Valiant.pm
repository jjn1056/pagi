package PAGI::Simple::View::Role::Valiant;

use strict;
use warnings;
use experimental 'signatures';

use Role::Tiny;
use Valiant::HTML::Util::Form;
use Template::EmbeddedPerl::SafeString;

our $VERSION = '0.01';

=head1 NAME

PAGI::Simple::View::Role::Valiant - Valiant form builder integration for PAGI::Simple

=head1 SYNOPSIS

    # In your app setup:
    $app->views('./templates', {
        roles => ['PAGI::Simple::View::Role::Valiant'],
    });

    # In templates:
    <%= form_for($v->user, { action => '/users' }, sub ($fb) { %>
        <div class="field">
            <%= $fb->label('name') %>
            <%= $fb->input('name') %>
            <%= $fb->errors_for('name') %>
        </div>
        <%= $fb->submit('Save') %>
    <% }) %>

=head1 DESCRIPTION

This role adds Valiant form builder support to PAGI::Simple::View.
It provides the C<form_for> helper and exposes the FormBuilder (C<$fb>)
object within form blocks for building form fields.

=head2 Requirements

Models used with C<form_for> should use L<Valiant::Validations> for
validation and error handling.

=head1 TEMPLATE HELPERS

=head2 form_for

    <%= form_for($model, \%options, sub ($fb) { ... }) %>

Create an HTML form bound to a model. The form builder C<$fb> provides
methods for generating form fields.

Options:

=over 4

=item action - Form action URL (required for PAGI::Simple)

=item method - HTTP method (default: 'post')

=item html - Additional HTML attributes for the form tag

=back

Example:

    <%= form_for($v->user, { action => '/users', method => 'post' }, sub ($fb) { %>
        <%= $fb->label('email') %>
        <%= $fb->input('email', { type => 'email', class => 'form-control' }) %>
        <%= $fb->errors_for('email', { class => 'text-danger' }) %>
        <%= $fb->submit('Save', { class => 'btn btn-primary' }) %>
    <% }) %>

=head2 FormBuilder Methods

Inside the form_for block, C<$fb> provides these methods:

=head3 Field Methods

=over 4

=item $fb->input($name, \%opts) - Text input

=item $fb->password($name, \%opts) - Password input

=item $fb->text_area($name, \%opts) - Textarea

=item $fb->checkbox($name, \%opts) - Checkbox

=item $fb->radio_button($name, $value, \%opts) - Radio button

=item $fb->select($name, \@options, \%opts) - Select dropdown

=item $fb->hidden($name, \%opts) - Hidden input

=item $fb->date_field($name, \%opts) - Date input

=item $fb->datetime_local_field($name, \%opts) - Datetime-local input

=item $fb->time_field($name, \%opts) - Time input

=back

=head3 Label and Error Methods

=over 4

=item $fb->label($name, $text, \%opts) - Label for field

=item $fb->errors_for($name, \%opts) - Error messages for field

=item $fb->model_errors(\%opts) - Model-level errors

=back

=head3 Button Methods

=over 4

=item $fb->submit($text, \%opts) - Submit button

=item $fb->button($name, \%opts, $text) - Generic button

=back

=head3 Nested Forms

=over 4

=item $fb->fields_for($name, sub ($nested_fb) { ... }) - Nested model fields

=back

=head2 htmx Integration

Add htmx attributes directly to form elements:

    <%= form_for($v->user, {
        action => '/users',
        html => {
            'hx-post' => '/users',
            'hx-target' => '#result',
            'hx-swap' => 'outerHTML'
        }
    }, sub ($fb) { %>
        <%= $fb->input('name', {
            'hx-post' => '/validate/name',
            'hx-trigger' => 'blur changed delay:500ms',
            'hx-target' => 'next .error'
        }) %>
        <span class="error"></span>
        <%= $fb->submit('Save') %>
    <% }) %>

=cut

# Accessor for the Form utility object (cached per render context)
sub _valiant_form ($self, $ctx) {
    $ctx->{_valiant_form} //= Valiant::HTML::Util::Form->new(view => $ctx);
}

=head1 HELPER METHODS

These methods are automatically available as template helpers.

=cut

# Helper: form_for
# Note: helper_ prefix methods receive ($self, $render_ctx, @args)
sub helper_form_for ($self, $ctx, $model, @args) {
    my $form = $self->_valiant_form($ctx);
    my $result = $form->form_for($model, @args);
    # Return as raw HTML (already safe)
    return Template::EmbeddedPerl::SafeString::raw($result);
}

# ============================================================================
# FormTags Helpers - Standalone tag generation (no model binding required)
# ============================================================================

# List of FormTags methods to expose as template helpers
my @FORMTAGS_HELPERS = qw(
    form_tag
    input_tag
    password_tag
    hidden_tag
    checkbox_tag
    radio_button_tag
    text_area_tag
    select_tag
    option_tag
    options_for_select
    options_from_collection_for_select
    label_tag
    submit_tag
    button_tag
    fieldset_tag
    legend_tag
);

# Dynamically generate helper methods for each FormTags method
for my $helper (@FORMTAGS_HELPERS) {
    no strict 'refs';
    my $method_name = "helper_$helper";
    *{$method_name} = sub {
        my ($self, $ctx, @args) = @_;
        my $form = $self->_valiant_form($ctx);
        my $result = $form->$helper(@args);
        return Template::EmbeddedPerl::SafeString::raw($result);
    };
}

1;

__END__

=head1 STANDALONE TAG HELPERS

In addition to C<form_for>, this role provides standalone tag helpers from
L<Valiant::HTML::Util::FormTags>. These are useful for forms that don't bind
to a model, or for generating individual form elements outside of C<form_for>.

=head2 form_tag

    <%= form_tag('/search', { method => 'GET', class => 'search-form' }, sub { %>
        <%= input_tag('q', { placeholder => 'Search...' }) %>
        <%= submit_tag('Search') %>
    <% }) %>

Create a form without model binding. Useful for search forms, login forms,
or any form that doesn't map to a Valiant model.

Options:

=over 4

=item method - HTTP method (default: 'POST')

=item class, id, style - Standard HTML attributes

=item Any other attributes are passed through to the form tag

=back

=head2 input_tag

    <%= input_tag('username', { class => 'form-control', placeholder => 'Username' }) %>
    <%= input_tag('email', { type => 'email', required => 1 }) %>

Generate a text input. Default type is 'text'.

=head2 password_tag

    <%= password_tag('password', { class => 'form-control' }) %>

Generate a password input field.

=head2 hidden_tag

    <%= hidden_tag('csrf_token', $token) %>
    <%= hidden_tag('return_url', '/dashboard') %>

Generate a hidden input field.

=head2 checkbox_tag

    <%= checkbox_tag('remember_me', 1, { checked => $remember }) %>
    <%= checkbox_tag('agree_tos', 'yes', { required => 1 }) %>

Generate a checkbox input. First argument is name, second is value.

With htmx:

    <%= checkbox_tag('toggle', 1, {
        checked => $item->active,
        'hx-post' => '/items/toggle',
        'hx-target' => '#item-list',
    }) %>

=head2 radio_button_tag

    <%= radio_button_tag('color', 'red', { checked => $color eq 'red' }) %>
    <%= radio_button_tag('color', 'blue', { checked => $color eq 'blue' }) %>
    <%= radio_button_tag('color', 'green', { checked => $color eq 'green' }) %>

Generate a radio button. First argument is name, second is value.

=head2 text_area_tag

    <%= text_area_tag('bio', $user->bio, { rows => 5, cols => 40 }) %>
    <%= text_area_tag('comments', '', { placeholder => 'Enter comments...' }) %>

Generate a textarea element.

=head2 select_tag

    <%= select_tag('country', options_for_select(\@countries, $selected)) %>

Generate a select dropdown. Usually used with C<options_for_select>.

=head2 option_tag

    <%= option_tag('United States', { value => 'US' }) %>
    <%= option_tag('Canada', { value => 'CA', selected => 1 }) %>

Generate a single option element. First argument is the label text,
second is options hash including C<value>.

=head2 options_for_select

    # Simple array of values (value = label)
    <%= options_for_select(['red', 'green', 'blue'], $current) %>

    # Array of [label, value] pairs
    <%= options_for_select([
        ['Red', 'red'],
        ['Green', 'green'],
        ['Blue', 'blue'],
    ], $current) %>

    # With option groups
    <%= options_for_select([
        ['Primary' => [['Red', 'red'], ['Blue', 'blue']]],
        ['Secondary' => [['Green', 'green'], ['Orange', 'orange']]],
    ], $current) %>

Generate option tags for a select. The second argument is the currently
selected value (or arrayref for multi-select).

=head2 options_from_collection_for_select

    <%= options_from_collection_for_select(
        \@users,           # Collection of objects
        'id',              # Value method
        'name',            # Label method
        $selected_id       # Currently selected value
    ) %>

Generate options from a collection of objects. Calls the specified methods
on each object to get the value and label.

=head2 label_tag

    <%= label_tag('email', 'Email Address') %>
    <%= label_tag('email', 'Email Address', { class => 'form-label' }) %>

Generate a label element. First argument is the 'for' attribute (field name),
second is the label text.

=head2 submit_tag

    <%= submit_tag('Save') %>
    <%= submit_tag('Delete', { class => 'btn btn-danger', 'data-confirm' => 'Are you sure?' }) %>

Generate a submit button.

=head2 button_tag

    <%= button_tag('Cancel', { type => 'button', onclick => 'history.back()' }) %>
    <%= button_tag('Load More', { type => 'button', 'hx-get' => '/more', 'hx-target' => '#list' }) %>

Generate a button element. Default type is 'submit'.

=head2 fieldset_tag

    <%= fieldset_tag({ class => 'address-fields' }, sub { %>
        <%= legend_tag('Shipping Address') %>
        <%= label_tag('street', 'Street') %>
        <%= input_tag('street') %>
    <% }) %>

Generate a fieldset element to group related form fields.

=head2 legend_tag

    <%= legend_tag('Personal Information') %>
    <%= legend_tag('Contact Details', { class => 'section-title' }) %>

Generate a legend element for a fieldset.

=head1 COMPLETE EXAMPLES

=head2 Search Form (No Model)

    <%= form_tag('/search', { method => 'GET', class => 'search-form' }, sub { %>
        <div class="search-box">
            <%= input_tag('q', {
                placeholder => 'Search...',
                value => $v->{query},
                autofocus => 1,
            }) %>
            <%= select_tag('category', options_for_select([
                ['All Categories', ''],
                ['Books', 'books'],
                ['Electronics', 'electronics'],
                ['Clothing', 'clothing'],
            ], $v->{category})) %>
            <%= submit_tag('Search', { class => 'btn btn-primary' }) %>
        </div>
    <% }) %>

=head2 Login Form

    <%= form_tag('/login', { class => 'login-form' }, sub { %>
        <%= hidden_tag('return_to', $v->{return_url}) %>

        <div class="field">
            <%= label_tag('email', 'Email') %>
            <%= input_tag('email', { type => 'email', required => 1 }) %>
        </div>

        <div class="field">
            <%= label_tag('password', 'Password') %>
            <%= password_tag('password', { required => 1 }) %>
        </div>

        <div class="field">
            <%= checkbox_tag('remember', 1) %>
            <%= label_tag('remember', 'Remember me') %>
        </div>

        <%= submit_tag('Sign In', { class => 'btn btn-primary' }) %>
    <% }) %>

=head2 Filter Form with htmx

    <%= form_tag('/products', { method => 'GET' }, sub { %>
        <%= select_tag('status', options_for_select([
            ['All', ''],
            ['Active', 'active'],
            ['Inactive', 'inactive'],
        ], $v->{status}), {
            'hx-get' => '/products',
            'hx-target' => '#product-list',
            'hx-trigger' => 'change',
        }) %>
    <% }) %>

=head2 Dynamic Options from Database

    # In controller:
    $c->render('products/new',
        categories => [$category_service->all],
        product => $product,
    );

    # In template:
    <%= form_for($v->product, { action => '/products' }, sub ($fb) { %>
        <%= $fb->label('name') %>
        <%= $fb->input('name') %>

        <%= $fb->label('category_id') %>
        <%= select_tag('product.category_id',
            options_from_collection_for_select(
                $v->{categories},
                'id',
                'name',
                $v->product->category_id
            )
        ) %>

        <%= $fb->submit('Create Product') %>
    <% }) %>

=head1 SEE ALSO

L<PAGI::Simple::View>, L<Valiant::HTML::FormBuilder>, L<Valiant::Validations>,
L<Valiant::HTML::Util::FormTags>

=head1 AUTHOR

PAGI Contributors

=cut
