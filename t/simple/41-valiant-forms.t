#!/usr/bin/env perl

use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

# =============================================================================
# PAGI::Simple Valiant Form Integration Tests
#
# Tests for form_for helper and Valiant::HTML::FormBuilder integration
# =============================================================================

use lib 'lib';

# Check if Valiant is available
BEGIN {
    eval { require Valiant::Validations; 1 }
        or plan skip_all => 'Valiant::Validations not installed';
}

use PAGI::Simple::View;

# Create temp directory for templates
my $tempdir = tempdir(CLEANUP => 1);
make_path("$tempdir/templates");

# Helper to create a template file
sub create_template ($name, $content) {
    my $path = "$tempdir/templates/$name.html.ep";
    my $dir = $path =~ s{/[^/]+$}{}r;
    make_path($dir) unless -d $dir;
    open my $fh, '>', $path or die "Cannot create $path: $!";
    print $fh $content;
    close $fh;
}

# Helper to create a view with Valiant role and signatures enabled
sub create_view () {
    return PAGI::Simple::View->new(
        template_dir => "$tempdir/templates",
        roles        => ['PAGI::Simple::View::Role::Valiant'],
        preamble     => 'use experimental "signatures";',
    );
}

# =============================================================================
# Test Model with Valiant::Validations
# =============================================================================
{
    package TestUser;
    use Moo;
    use Valiant::Validations;

    has 'id'     => (is => 'rw', default => '');
    has 'name'   => (is => 'rw', default => '');
    has 'email'  => (is => 'rw', default => '');
    has 'age'    => (is => 'rw', default => 0);
    has 'role'   => (is => 'rw', default => 'user');
    has 'active' => (is => 'rw', default => 0);
    has 'bio'    => (is => 'rw', default => '');

    validates name  => (presence => 1, length => { minimum => 2, maximum => 50 });
    validates email => (presence => 1);
    validates age   => (numericality => { greater_than => 0 });
}

# Nested model for fields_for tests
{
    package TestProfile;
    use Moo;
    use Valiant::Validations;

    has 'bio'     => (is => 'rw', default => '');
    has 'website' => (is => 'rw', default => '');

    validates bio => (length => { maximum => 500 });
}

# User with nested profile
{
    package TestUserWithProfile;
    use Moo;
    use Valiant::Validations;

    has 'name'    => (is => 'rw', default => '');
    has 'profile' => (is => 'rw', default => sub { TestProfile->new });

    validates name => (presence => 1);

    sub accept_nested_for { ['profile'] }
}

# =============================================================================
# Test 1: Basic form_for renders form
# =============================================================================
subtest 'Basic form_for renders form' => sub {
    my $view = create_view();

    create_template('basic_form', <<'TEMPLATE');
<%= form_for($v->user, { action => '/users', method => 'post' }, sub ($view, $fb, $model) { %>
<%= $fb->input('name') %>
<% }) %>
TEMPLATE

    my $user = TestUser->new(name => 'John');
    my $html = $view->render('basic_form', user => $user);

    like $html, qr/<form[^>]+action="\/users"/, 'Form has action';
    like $html, qr/<form[^>]+method="post"/, 'Form has method';
    like $html, qr/<input[^>]+name="test_user\.name"/, 'Input has namespaced name';
    like $html, qr/<input[^>]+value="John"/, 'Input has value from model';
};

# =============================================================================
# Test 2: form_for with label and errors
# =============================================================================
subtest 'form_for with label and errors_for' => sub {
    my $view = create_view();

    create_template('form_with_errors', <<'TEMPLATE');
<%= form_for($v->user, { action => '/users' }, sub ($view, $fb, $model) { %>
<%= $fb->label('name') %>
<%= $fb->input('name') %>
<%= $fb->errors_for('name') %>
<% }) %>
TEMPLATE

    # Create user with invalid data and validate
    my $user = TestUser->new(name => 'X');
    $user->validate;

    my $html = $view->render('form_with_errors', user => $user);

    like $html, qr/<label[^>]+for="test_user_name"/, 'Label has for attribute';
    like $html, qr/<input[^>]+id="test_user_name"/, 'Input has matching id';
    like $html, qr/too short|minimum/, 'Error message shown';
};

# =============================================================================
# Test 3: form_for with various input types
# =============================================================================
subtest 'form_for with various input types' => sub {
    my $view = create_view();

    create_template('form_input_types', <<'TEMPLATE');
<%= form_for($v->user, { action => '/users' }, sub ($view, $fb, $model) { %>
<%= $fb->input('name') %>
<%= $fb->input('email', { type => 'email' }) %>
<%= $fb->input('age', { type => 'number' }) %>
<%= $fb->hidden('id') %>
<%= $fb->submit('Save') %>
<% }) %>
TEMPLATE

    my $user = TestUser->new(name => 'Jane', email => 'jane@example.com', age => 25);
    my $html = $view->render('form_input_types', user => $user);

    like $html, qr/<input[^>]+name="test_user\.name"[^>]+type="text"/, 'Text input';
    like $html, qr/<input[^>]+name="test_user\.email"[^>]+type="email"/, 'Email input';
    like $html, qr/<input[^>]+name="test_user\.age"[^>]+type="number"/, 'Number input';
    like $html, qr/<input[^>]+name="test_user\.id"[^>]+type="hidden"/, 'Hidden input';
    like $html, qr/<button[^>]*type="submit"|<input[^>]+type="submit"/, 'Submit button';
};

# =============================================================================
# Test 4: form_for with htmx attributes
# =============================================================================
subtest 'form_for with htmx attributes' => sub {
    my $view = create_view();

    create_template('form_htmx', <<'TEMPLATE');
<%= form_for($v->user, {
    action => '/users',
    html => {
        'hx-post' => '/users',
        'hx-target' => '#result',
        'hx-swap' => 'outerHTML'
    }
}, sub ($view, $fb, $model) { %>
<%= $fb->input('name', {
    'hx-post' => '/validate/name',
    'hx-trigger' => 'blur'
}) %>
<% }) %>
TEMPLATE

    my $user = TestUser->new();
    my $html = $view->render('form_htmx', user => $user);

    like $html, qr/hx-post="\/users"/, 'Form has hx-post';
    like $html, qr/hx-target="#result"/, 'Form has hx-target';
    like $html, qr/hx-swap="outerHTML"/, 'Form has hx-swap';
    like $html, qr/<input[^>]+hx-post="\/validate\/name"/, 'Input has hx-post';
    like $html, qr/<input[^>]+hx-trigger="blur"/, 'Input has hx-trigger';
};

# =============================================================================
# Test 5: form_for with CSS classes on errors
# =============================================================================
subtest 'form_for with error classes' => sub {
    my $view = create_view();

    create_template('form_error_classes', <<'TEMPLATE');
<%= form_for($v->user, { action => '/users' }, sub ($view, $fb, $model) { %>
<%= $fb->input('name', { class => 'form-control', errors_classes => 'is-invalid' }) %>
<%= $fb->errors_for('name', { class => 'invalid-feedback' }) %>
<% }) %>
TEMPLATE

    my $user = TestUser->new(name => 'X');
    $user->validate;

    my $html = $view->render('form_error_classes', user => $user);

    like $html, qr/<input[^>]+class="[^"]*form-control[^"]*is-invalid[^"]*"/,
        'Input has base class and error class';
    like $html, qr/class="[^"]*invalid-feedback[^"]*"/, 'Errors container has class';
};

# =============================================================================
# Test 6: form_for model_errors
# =============================================================================
subtest 'form_for model_errors' => sub {
    my $view = create_view();

    create_template('form_model_errors', <<'TEMPLATE');
<%= form_for($v->user, { action => '/users' }, sub ($view, $fb, $model) { %>
<%= $fb->model_errors({ class => 'alert alert-danger' }) %>
<%= $fb->input('name') %>
<% }) %>
TEMPLATE

    my $user = TestUser->new(name => '');
    $user->validate;  # This will fail name presence validation

    my $html = $view->render('form_model_errors', user => $user);

    # The form should render (model_errors shows field errors on model level)
    like $html, qr/<form/, 'Form renders';
    like $html, qr/<input[^>]+name="test_user\.name"/, 'Input renders';
};

# =============================================================================
# Test 7: form_for select field
# =============================================================================
subtest 'form_for select field' => sub {
    my $view = create_view();

    create_template('form_select', <<'TEMPLATE');
<%= form_for($v->user, { action => '/users' }, sub ($view, $fb, $model) { %>
<%= $fb->select('role', [
    ['admin', 'Administrator'],
    ['user', 'Regular User'],
    ['guest', 'Guest']
], { class => 'form-select' }) %>
<% }) %>
TEMPLATE

    my $user = TestUser->new();
    my $html = $view->render('form_select', user => $user);

    like $html, qr/<select[^>]+name="test_user\.role"/, 'Select has name';
    like $html, qr/<select[^>]+class="form-select"/, 'Select has class';
    # Valiant select uses [text, value] or [value, text] format - just check options exist
    like $html, qr/<option[^>]*>admin<\/option>|<option[^>]+value="admin"/, 'Has admin option';
    like $html, qr/<option[^>]*>user<\/option>|<option[^>]+value="user"/, 'Has user option';
};

# =============================================================================
# Test 8: form_for checkbox
# =============================================================================
subtest 'form_for checkbox' => sub {
    my $view = create_view();

    create_template('form_checkbox', <<'TEMPLATE');
<%= form_for($v->user, { action => '/users' }, sub ($view, $fb, $model) { %>
<%= $fb->checkbox('active', { class => 'form-check-input' }) %>
<%= $fb->label('active', 'Active User') %>
<% }) %>
TEMPLATE

    my $user = TestUser->new();
    my $html = $view->render('form_checkbox', user => $user);

    like $html, qr/<input[^>]+type="checkbox"/, 'Checkbox renders';
    like $html, qr/<input[^>]+name="test_user\.active"/, 'Checkbox has name';
};

# =============================================================================
# Test 9: form_for textarea
# =============================================================================
subtest 'form_for textarea' => sub {
    my $view = create_view();

    create_template('form_textarea', <<'TEMPLATE');
<%= form_for($v->user, { action => '/users' }, sub ($view, $fb, $model) { %>
<%= $fb->text_area('bio', { rows => 5, class => 'form-control' }) %>
<% }) %>
TEMPLATE

    my $user = TestUser->new();
    my $html = $view->render('form_textarea', user => $user);

    like $html, qr/<textarea[^>]+name="test_user\.bio"/, 'Textarea has name';
    like $html, qr/<textarea[^>]+rows="5"/, 'Textarea has rows';
    like $html, qr/<textarea[^>]+class="form-control"/, 'Textarea has class';
};

# =============================================================================
# Test 10: Valid model shows no errors
# =============================================================================
subtest 'Valid model shows no errors' => sub {
    my $view = create_view();

    create_template('form_valid', <<'TEMPLATE');
<%= form_for($v->user, { action => '/users' }, sub ($view, $fb, $model) { %>
<%= $fb->input('name') %>
<%= $fb->errors_for('name') %>
<% }) %>
TEMPLATE

    my $user = TestUser->new(name => 'Valid Name', email => 'test@example.com', age => 25);
    $user->validate;

    my $html = $view->render('form_valid', user => $user);

    like $html, qr/<input[^>]+value="Valid Name"/, 'Shows valid value';
    # errors_for should be empty for valid field
    unlike $html, qr/too short|minimum|error/i, 'No error messages for valid data';
};

done_testing;
