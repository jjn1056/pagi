#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;

use lib 'lib';

# ============================================================================
# Test FormTags helpers exposed through Valiant role
# ============================================================================

use PAGI::Simple::View;

# Create a view with the Valiant role
my $view = PAGI::Simple::View->new(
    template_dir => 't/templates',
    cache        => 0,
    roles        => ['PAGI::Simple::View::Role::Valiant'],
);

# ============================================================================
# INPUT TAG HELPERS
# ============================================================================

subtest 'input_tag helper' => sub {
    my $html = $view->render_string(
        '<%= input_tag("username") %>'
    );
    like $html, qr/<input/, 'generates input element';
    like $html, qr/name="username"/, 'has name attribute';
    like $html, qr/type="text"/, 'default type is text';

    # With options
    $html = $view->render_string(
        '<%= input_tag("email", { type => "email", class => "form-control", required => 1 }) %>'
    );
    like $html, qr/type="email"/, 'type can be overridden';
    like $html, qr/class="form-control"/, 'class attribute set';
    like $html, qr/required/, 'required attribute set';
};

subtest 'password_tag helper' => sub {
    my $html = $view->render_string(
        '<%= password_tag("secret") %>'
    );
    like $html, qr/<input/, 'generates input element';
    like $html, qr/name="secret"/, 'has name attribute';
    like $html, qr/type="password"/, 'type is password';
};

subtest 'hidden_tag helper' => sub {
    my $html = $view->render_string(
        '<%= hidden_tag("csrf", "token123") %>'
    );
    like $html, qr/<input/, 'generates input element';
    like $html, qr/type="hidden"/, 'type is hidden';
    like $html, qr/name="csrf"/, 'has name attribute';
    like $html, qr/value="token123"/, 'has value attribute';
};

subtest 'text_area_tag helper' => sub {
    my $html = $view->render_string(
        '<%= text_area_tag("bio", "Hello world", { rows => 5 }) %>'
    );
    like $html, qr/<textarea/, 'generates textarea element';
    like $html, qr/name="bio"/, 'has name attribute';
    like $html, qr/rows="5"/, 'has rows attribute';
    like $html, qr/>Hello world</, 'contains content';
};

# ============================================================================
# CHECKBOX AND RADIO HELPERS
# ============================================================================

subtest 'checkbox_tag helper' => sub {
    my $html = $view->render_string(
        '<%= checkbox_tag("remember", 1) %>'
    );
    like $html, qr/<input/, 'generates input element';
    like $html, qr/type="checkbox"/, 'type is checkbox';
    like $html, qr/name="remember"/, 'has name attribute';
    like $html, qr/value="1"/, 'has value attribute';

    # With checked option
    $html = $view->render_string(
        '<%= checkbox_tag("active", "yes", { checked => 1 }) %>'
    );
    like $html, qr/checked/, 'checked attribute present when true';

    # Without checked
    $html = $view->render_string(
        '<%= checkbox_tag("active", "yes", { checked => 0 }) %>'
    );
    unlike $html, qr/checked/, 'checked attribute absent when false';
};

subtest 'radio_button_tag helper' => sub {
    my $html = $view->render_string(
        '<%= radio_button_tag("color", "red") %>'
    );
    like $html, qr/<input/, 'generates input element';
    like $html, qr/type="radio"/, 'type is radio';
    like $html, qr/name="color"/, 'has name attribute';
    like $html, qr/value="red"/, 'has value attribute';
};

# ============================================================================
# SELECT AND OPTION HELPERS
# ============================================================================

subtest 'select_tag with options_for_select' => sub {
    my $html = $view->render_string(<<'TEMPLATE');
<%= select_tag("color", options_for_select([
    ['Red', 'red'],
    ['Green', 'green'],
    ['Blue', 'blue'],
], 'green')) %>
TEMPLATE

    like $html, qr/<select/, 'generates select element';
    like $html, qr/name="color"/, 'has name attribute';
    like $html, qr/<option.*value="red".*>Red<\/option>/, 'has red option';
    # Note: Valiant outputs 'selected' before 'value'
    like $html, qr/<option\s+selected\s+value="green">Green<\/option>/, 'green option is selected';
    like $html, qr/<option.*value="blue".*>Blue<\/option>/, 'has blue option';
};

subtest 'options_for_select with simple array' => sub {
    my $html = $view->render_string(<<'TEMPLATE');
<%= options_for_select(['apple', 'banana', 'cherry'], 'banana') %>
TEMPLATE

    like $html, qr/<option.*value="apple".*>apple<\/option>/, 'has apple option';
    # Note: Valiant outputs 'selected' before 'value'
    like $html, qr/<option\s+selected\s+value="banana"/, 'banana is selected';
    like $html, qr/<option.*value="cherry".*>cherry<\/option>/, 'has cherry option';
};

subtest 'option_tag helper' => sub {
    # option_tag signature: option_tag($label, { value => $value, ... })
    my $html = $view->render_string(
        '<%= option_tag("United States", { value => "US" }) %>'
    );
    like $html, qr/<option/, 'generates option element';
    like $html, qr/value="US"/, 'has value attribute';
    like $html, qr/>United States</, 'has label text';
};

# ============================================================================
# LABEL AND BUTTON HELPERS
# ============================================================================

subtest 'label_tag helper' => sub {
    my $html = $view->render_string(
        '<%= label_tag("email", "Email Address") %>'
    );
    like $html, qr/<label/, 'generates label element';
    like $html, qr/for="email"/, 'has for attribute';
    like $html, qr/>Email Address</, 'has label text';

    # With options
    $html = $view->render_string(
        '<%= label_tag("name", "Full Name", { class => "required" }) %>'
    );
    like $html, qr/class="required"/, 'has class attribute';
};

subtest 'submit_tag helper' => sub {
    my $html = $view->render_string(
        '<%= submit_tag("Save") %>'
    );
    like $html, qr/<input/, 'generates input element';
    like $html, qr/type="submit"/, 'type is submit';
    like $html, qr/value="Save"/, 'has value attribute';

    # With options
    $html = $view->render_string(
        '<%= submit_tag("Delete", { class => "btn-danger" }) %>'
    );
    like $html, qr/class="btn-danger"/, 'has class attribute';
};

subtest 'button_tag helper' => sub {
    my $html = $view->render_string(
        '<%= button_tag("Click Me") %>'
    );
    like $html, qr/<button/, 'generates button element';
    like $html, qr/>Click Me</, 'has button text';
};

# ============================================================================
# FIELDSET AND LEGEND HELPERS
# ============================================================================

subtest 'legend_tag helper' => sub {
    my $html = $view->render_string(
        '<%= legend_tag("Personal Info") %>'
    );
    like $html, qr/<legend/, 'generates legend element';
    like $html, qr/>Personal Info</, 'has legend text';
};

# ============================================================================
# INTEGRATION: FORM_TAG WITH NESTED HELPERS
# ============================================================================

subtest 'form_tag with nested helpers' => sub {
    my $html = $view->render_string(<<'TEMPLATE');
<%= form_tag('/login', { method => 'POST', class => 'login-form' }, sub { %>
    <%= label_tag('email', 'Email') %>
    <%= input_tag('email', { type => 'email' }) %>
    <%= label_tag('password', 'Password') %>
    <%= password_tag('password') %>
    <%= checkbox_tag('remember', 1) %>
    <%= submit_tag('Sign In') %>
<% }) %>
TEMPLATE

    like $html, qr/<form/, 'generates form element';
    like $html, qr/action="\/login"/, 'has action attribute';
    like $html, qr/method="post"/i, 'has method attribute';
    like $html, qr/class="login-form"/, 'has class attribute';
    like $html, qr/<label.*for="email"/, 'has email label';
    like $html, qr/<input.*type="email"/, 'has email input';
    like $html, qr/<input.*type="password"/, 'has password input';
    like $html, qr/<input.*type="checkbox"/, 'has checkbox';
    like $html, qr/<input.*type="submit"/, 'has submit button';
    like $html, qr/<\/form>/, 'form is closed';
};

# ============================================================================
# HTMX INTEGRATION
# ============================================================================

subtest 'FormTags helpers with htmx attributes' => sub {
    my $html = $view->render_string(<<'TEMPLATE');
<%= checkbox_tag('toggle', 1, {
    checked => 1,
    'hx-post' => '/toggle',
    'hx-target' => '#result',
    'hx-swap' => 'outerHTML',
}) %>
TEMPLATE

    like $html, qr/type="checkbox"/, 'is checkbox';
    like $html, qr/checked/, 'is checked';
    like $html, qr/hx-post="\/toggle"/, 'has hx-post attribute';
    like $html, qr/hx-target="#result"/, 'has hx-target attribute';
    like $html, qr/hx-swap="outerHTML"/, 'has hx-swap attribute';
};

subtest 'select_tag with htmx' => sub {
    my $html = $view->render_string(<<'TEMPLATE');
<%= select_tag('filter', options_for_select([
    ['All', ''],
    ['Active', 'active'],
], ''), {
    'hx-get' => '/items',
    'hx-trigger' => 'change',
}) %>
TEMPLATE

    like $html, qr/<select/, 'generates select';
    like $html, qr/hx-get="\/items"/, 'has hx-get attribute';
    like $html, qr/hx-trigger="change"/, 'has hx-trigger attribute';
};

# ============================================================================
# REAL-WORLD PATTERNS
# ============================================================================

subtest 'Search form pattern' => sub {
    my $html = $view->render_string(<<'TEMPLATE', query => 'test', category => 'books');
<%= form_tag('/search', { method => 'GET' }, sub { %>
    <%= input_tag('q', { value => $v->{query}, placeholder => 'Search...' }) %>
    <%= select_tag('cat', options_for_select([
        ['All', ''],
        ['Books', 'books'],
        ['Movies', 'movies'],
    ], $v->{category})) %>
    <%= submit_tag('Go') %>
<% }) %>
TEMPLATE

    like $html, qr/method="GET"/i, 'GET method for search';
    like $html, qr/value="test"/, 'search query preserved';
    # Note: Valiant outputs 'selected' before 'value'
    like $html, qr/selected\s+value="books"/, 'category preserved';
};

subtest 'Filter controls pattern' => sub {
    my $html = $view->render_string(<<'TEMPLATE', status => 'active');
<div class="filters">
    <%= label_tag('status', 'Status:') %>
    <%= select_tag('status', options_for_select([
        ['All', ''],
        ['Active', 'active'],
        ['Completed', 'completed'],
    ], $v->{status}), {
        'hx-get' => '/items',
        'hx-target' => '#list',
    }) %>
</div>
TEMPLATE

    like $html, qr/<label.*for="status"/, 'has label';
    # Note: Valiant outputs 'selected' before 'value'
    like $html, qr/selected\s+value="active"/, 'current status selected';
    like $html, qr/hx-get="\/items"/, 'htmx integration works';
};

done_testing;
