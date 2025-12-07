package PAGI::Simple::View;

use strict;
use warnings;
use experimental 'signatures';

our $VERSION = '0.01';

use Carp qw(croak);
use Scalar::Util qw(blessed);
use File::Spec;
use Template::EmbeddedPerl;
use PAGI::Simple::View::Helpers;
use PAGI::Simple::View::Vars;

=head1 NAME

PAGI::Simple::View - Template rendering engine for PAGI::Simple

=head1 SYNOPSIS

    use PAGI::Simple::View;

    my $view = PAGI::Simple::View->new(
        template_dir => './templates',
        auto_escape  => 1,
        extension    => '.html.ep',
    );

    # Render a template
    my $html = $view->render('index', title => 'Home');

    # Render a partial
    my $partial = $view->include('todos/_item', todo => $todo);

=head1 DESCRIPTION

PAGI::Simple::View provides template rendering using Template::EmbeddedPerl.
It supports layouts, partials, template caching, and custom helpers.

=head1 METHODS

=cut

=head2 new

    my $view = PAGI::Simple::View->new(%options);

Create a new View instance.

Options:

=over 4

=item * template_dir - Directory containing templates (required)

=item * extension - Template file extension (default: '.html.ep')

=item * auto_escape - Escape output by default (default: 1)

=item * cache - Cache compiled templates (default: 1)

=item * development - Development mode (disables cache, verbose errors)

=item * helpers - Hashref of custom helper functions

=item * roles - Arrayref of role names to compose into view

=item * prepend - Extra Perl code to add at start of template subroutine

=item * preamble - Package-level Perl code (e.g., use statements)

To enable subroutine signatures in templates:

    my $view = PAGI::Simple::View->new(
        template_dir => './templates',
        preamble     => 'use experimental "signatures";',
    );

=back

=cut

sub new ($class, %args) {
    my $self = bless {
        template_dir => $args{template_dir} // croak("template_dir is required"),
        extension    => $args{extension}    // '.html.ep',
        auto_escape  => $args{auto_escape}  // 1,
        cache        => $args{cache}        // 1,
        development  => $args{development}  // 0,
        helpers      => $args{helpers}      // {},
        roles        => $args{roles}        // [],
        prepend      => $args{prepend}      // '',   # Extra code for template sub
        preamble     => $args{preamble}     // '',   # Package-level code (use statements)
        _cache       => {},                # Template cache
        _context     => undef,             # Current request context
        _blocks      => {},                # Named content blocks
        _layout      => undef,             # Current layout
        _layout_vars => {},                # Variables to pass to layout
        _app         => $args{app},        # Reference to PAGI::Simple app
    }, $class;

    # Disable cache in development mode
    if ($self->{development}) {
        $self->{cache} = 0;
    }

    # Apply roles
    for my $role (@{$self->{roles}}) {
        $self->_apply_role($role);
    }

    return $self;
}

# Internal: Apply a role to this instance
sub _apply_role ($self, $role) {
    # Load the role module
    eval "require $role" or croak("Cannot load role $role: $@");

    # Use Role::Tiny to apply the role
    require Role::Tiny;
    Role::Tiny->apply_roles_to_object($self, $role);
}

=head2 template_dir

    my $dir = $view->template_dir;

Returns the template directory path.

=cut

sub template_dir ($self) {
    return $self->{template_dir};
}

=head2 extension

    my $ext = $view->extension;

Returns the template file extension.

=cut

sub extension ($self) {
    return $self->{extension};
}

=head2 app

    my $app = $view->app;

Returns the PAGI::Simple application instance.

=cut

sub app ($self) {
    return $self->{_app};
}

=head2 render

    my $html = $view->render($template_name, %vars);

Render a template file with the given variables.
Returns the rendered HTML string.

If rendering for an htmx request (detected via _context), automatically
returns just the content block without layout wrapping.

=head3 Layout Control Options

You can explicitly control layout rendering with the C<layout> option:

    # Force layout ON (even for htmx requests)
    $view->render('page', layout => 1, %vars);

    # Force layout OFF (even for browser requests)
    $view->render('page', layout => 0, %vars);

    # Auto-detect (default): skip layout for htmx, use layout for browser
    $view->render('page', %vars);

This is useful when:

=over 4

=item * htmx request needs full page (e.g., hx-boost navigation)

=item * Browser request should skip layout (e.g., printable view, iframe embed)

=item * You want consistent behavior regardless of request type

=back

=cut

# Package variable to track current view during rendering
# This is needed because Template::EmbeddedPerl compiles helpers at template
# compile time, but we need them to access the current view at render time.
our $_current_view;

sub render ($self, $template_name, %vars) {
    # Extract layout control option (if provided)
    my $layout_override = delete $vars{layout};

    # Store any request context
    local $self->{_context} = $vars{_context} // $self->{_context};
    local $self->{_blocks} = {};
    local $self->{_layout} = undef;
    local $self->{_layout_vars} = {};

    # Set current view for helpers to access
    local $_current_view = $self;

    # Get compiled template
    my $template = $self->_get_template($template_name);

    # Render the template - pass vars hashref as first arg (accessed as $v)
    my $output = $template->render(\%vars);

    # Determine whether to use layout:
    # - layout => 1: force layout ON
    # - layout => 0: force layout OFF
    # - layout not specified: auto-detect (skip for htmx, use for browser)
    my $use_layout;
    if (defined $layout_override) {
        $use_layout = $layout_override ? 1 : 0;
    } else {
        # Auto-detect: skip layout for htmx requests
        my $is_htmx = 0;
        if ($self->{_context} && $self->{_context}->can('req')) {
            $is_htmx = $self->{_context}->req->is_htmx;
        }
        $use_layout = !$is_htmx;
    }

    # If a layout was set and we should use it, render it
    if ($self->{_layout} && $use_layout) {
        $output = $self->_render_layout($output, %vars);
    }

    return $output;
}

=head2 render_string

    my $html = $view->render_string($template_string, %vars);

Render a template from a string with the given variables.
This is useful for testing or dynamic templates.

=cut

sub render_string ($self, $template_string, %vars) {
    local $self->{_context} = $vars{_context} // $self->{_context};
    local $self->{_blocks} = {};
    local $self->{_layout} = undef;
    local $self->{_layout_vars} = {};
    local $_current_view = $self;

    # Compile the template string
    my $template = $self->_compile_template($template_string, 'string');

    # Render with vars hashref as first arg (accessed as $v)
    return $template->render(\%vars);
}

=head2 render_fragment

    my $html = $view->render_fragment($template_name, %vars);

Render a template as a fragment (without layout), regardless of request type.
Useful for explicitly returning partials.

=cut

sub render_fragment ($self, $template_name, %vars) {
    local $self->{_context} = $vars{_context} // $self->{_context};
    local $self->{_blocks} = {};
    local $self->{_layout} = undef;
    local $self->{_layout_vars} = {};
    local $_current_view = $self;

    my $template = $self->_get_template($template_name);

    # Always skip layout for fragments
    return $template->render(\%vars);
}

=head2 include

    my $html = $view->include($partial_name, %vars);

Render a partial template. Partial names can include a leading underscore
or not - the view will find the file either way.

=cut

sub include ($self, $partial_name, %vars) {
    my $template = $self->_get_template($partial_name);
    # Render with vars hashref as first arg (accessed as $v)
    my $html = $template->render(\%vars);
    # Return as SafeString (using raw, not new) so it won't be double-escaped
    return Template::EmbeddedPerl::SafeString::raw($html);
}

=head2 clear_cache

    $view->clear_cache;

Clear the template cache. Useful in development when templates change.

=cut

sub clear_cache ($self) {
    $self->{_cache} = {};
    return $self;
}

# Internal: Get a compiled template (from cache or compile fresh)
sub _get_template ($self, $name) {
    # Check cache first (unless disabled)
    if ($self->{cache} && exists $self->{_cache}{$name}) {
        return $self->{_cache}{$name};
    }

    # Find the template file
    my $path = $self->_find_template($name);
    unless ($path && -f $path) {
        my $msg = "Template not found: $name";
        $msg .= " (looked in $self->{template_dir})" if $self->{development};
        croak($msg);
    }

    # Read template source
    open my $fh, '<:utf8', $path or croak("Cannot read $path: $!");
    my $source = do { local $/; <$fh> };
    close $fh;

    # Compile the template
    my $compiled = $self->_compile_template($source, $name);

    # Cache if enabled
    if ($self->{cache}) {
        $self->{_cache}{$name} = $compiled;
    }

    return $compiled;
}

# Internal: Compile a template string
sub _compile_template ($self, $source, $name = 'string') {
    # Build prepend: our internal code + user's custom prepend
    my $prepend = 'my $v = PAGI::Simple::View::Vars->new(shift);';
    $prepend .= ' ' . $self->{prepend} if $self->{prepend};

    # Create engine with our settings
    my $engine = Template::EmbeddedPerl->new(
        prepend     => $prepend,  # Variables available as $v->name or $v->{name}
        preamble    => $self->{preamble},  # Package-level code (use statements)
        auto_escape => $self->{auto_escape},
        helpers     => $self->_get_all_helpers(),
    );

    return $engine->from_string($source);
}

# Internal: Get all helpers (default + custom)
# Merges Template::EmbeddedPerl default helpers with our view-specific helpers
sub _get_all_helpers ($self) {
    # Get default helpers from Template::EmbeddedPerl
    # These include: raw, safe, safe_concat, html_escape, url_encode,
    # escape_javascript, trim, mtrim, to_safe_string
    my $engine = Template::EmbeddedPerl->new();
    my %helpers = $engine->default_helpers();

    # Add our view-specific helpers
    my %view_helpers = %{$self->_get_engine_helpers()};
    %helpers = (%helpers, %view_helpers);

    # Add htmx helpers if Htmx module is available
    eval {
        require PAGI::Simple::View::Helpers::Htmx;
        my $htmx_helpers = PAGI::Simple::View::Helpers::Htmx::get_helpers($self);
        # Wrap htmx helpers to work with Template::EmbeddedPerl (receives $ep as first arg)
        for my $name (keys %$htmx_helpers) {
            my $original = $htmx_helpers->{$name};
            $helpers{$name} = sub {
                shift;  # Discard Template::EmbeddedPerl instance
                return $original->(@_);
            };
        }
    };

    # Add custom helpers from constructor
    for my $name (keys %{$self->{helpers}}) {
        my $original = $self->{helpers}{$name};
        $helpers{$name} = sub {
            shift;  # Discard Template::EmbeddedPerl instance
            return $original->(@_);
        };
    }

    # Add role-provided helpers (methods starting with helper_)
    {
        no strict 'refs';
        my $class = ref($self);
        for my $method (grep { /^helper_/ } keys %{"${class}::"}) {
            my $helper_name = $method =~ s/^helper_//r;
            $helpers{$helper_name} = sub {
                shift;  # Discard Template::EmbeddedPerl instance
                my $view = $_current_view or die "No current view set during rendering";
                return $view->$method(@_);
            };
        }
    }

    return \%helpers;
}

# Internal: Get helpers for Template::EmbeddedPerl engine
# Note: Template::EmbeddedPerl passes itself as the first arg to helpers
# IMPORTANT: These helpers must use $_current_view instead of $self because
# templates may be compiled once but rendered with different view instances.
sub _get_engine_helpers ($self) {
    return {
        # Include partial
        # Returns raw HTML (already rendered, should not be escaped again)
        include => sub {
            my $ep = shift;  # Template::EmbeddedPerl instance (for raw())
            my ($name, %vars) = @_;
            my $view = $_current_view or die "No current view set during rendering";
            my $html = $view->include($name, %vars);
            return $ep->raw($html);  # Return as safe string
        },
        # Layout helpers
        extends => sub {
            shift;  # Discard Template::EmbeddedPerl instance
            my ($layout, %vars) = @_;
            my $view = $_current_view or die "No current view set during rendering";
            $view->{_layout} = $layout;
            $view->{_layout_vars} = \%vars;
            return '';
        },
        # Retrieve content - main body or named block
        content => sub {
            my $ep = shift;  # Template::EmbeddedPerl instance (for raw())
            my ($name) = @_;
            my $view = $_current_view or die "No current view set during rendering";
            # If no name given, return main content; otherwise return named block
            $name //= 'content';
            return $ep->raw($view->{_blocks}{$name} // '');
        },
        # Set/append content to a named block
        content_for => sub {
            shift;  # Discard Template::EmbeddedPerl instance
            my ($name, $content) = @_;
            my $view = $_current_view or die "No current view set during rendering";
            # If content is a coderef, call it with $view and use the result
            if (ref($content) eq 'CODE') {
                $content = $content->($view);
            }
            $view->{_blocks}{$name} //= '';
            $view->{_blocks}{$name} .= $content;
            return '';
        },
        # Block helper (set named content block - replaces, doesn't append)
        block => sub {
            shift;  # Discard Template::EmbeddedPerl instance
            my ($name, $content) = @_;
            my $view = $_current_view or die "No current view set during rendering";
            # If content is a coderef, call it with $view and use the result
            if (ref($content) eq 'CODE') {
                $content = $content->($view);
            }
            $view->{_blocks}{$name} = $content;
            return '';
        },
        # Capture helper - capture template content into a variable
        capture => sub {
            shift;  # Discard Template::EmbeddedPerl instance
            my ($code) = @_;
            my $view = $_current_view or die "No current view set during rendering";
            return ref($code) eq 'CODE' ? $code->($view) : ($code // '');
        },
        # Route helper
        route => sub {
            shift;  # Discard Template::EmbeddedPerl instance
            my ($name, %params) = @_;
            my $view = $_current_view or die "No current view set during rendering";
            if ($view->{_app} && $view->{_app}->can('url_for')) {
                return $view->{_app}->url_for($name, %params) // '';
            }
            return '';
        },
    };
}

# Internal: Find a template file by name
sub _find_template ($self, $name) {
    my $ext = $self->{extension};
    my $dir = $self->{template_dir};

    # Try the name as-is
    my $path = File::Spec->catfile($dir, "$name$ext");
    return $path if -f $path;

    # If name contains '/', try adding underscore prefix to last segment (partial convention)
    if ($name =~ m{/}) {
        my @parts = split m{/}, $name;
        my $last = pop @parts;
        unless ($last =~ /^_/) {
            my $partial_name = join('/', @parts, "_$last");
            my $partial_path = File::Spec->catfile($dir, "$partial_name$ext");
            return $partial_path if -f $partial_path;
        }
    }

    return undef;
}

# Internal: Render a layout with content
sub _render_layout ($self, $content, %vars) {
    my $layout_name = $self->{_layout};
    my %layout_vars = %{$self->{_layout_vars}};

    # Store the content block
    $self->{_blocks}{content} = $content;

    # Reset layout tracking before rendering (layout may set its own extends)
    $self->{_layout} = undef;
    $self->{_layout_vars} = {};

    # Get compiled layout template
    my $template = $self->_get_template($layout_name);

    # Merge variables (layout vars override page vars)
    my %render_vars = (%vars, %layout_vars);

    my $output = $template->render(\%render_vars);

    # If the layout itself called extends(), recurse to render that layout
    if ($self->{_layout}) {
        $output = $self->_render_layout($output, %render_vars);
    }

    return $output;
}

=head2 context

    my $c = $view->context;

Returns the current request context (if rendering within a request).

=cut

sub context ($self) {
    return $self->{_context};
}

=head2 set_context

    $view->set_context($c);

Set the current request context.

=cut

sub set_context ($self, $c) {
    $self->{_context} = $c;
    return $self;
}

=head1 TEMPLATE SYNTAX

Templates use embedded Perl syntax:

    <% code %>           Execute Perl code
    <%= expression %>    Output expression (auto-escaped)
    <%== expression %>   Output raw (unescaped)
    % code               Line-based Perl code
    %= expression        Line-based output

=head2 Variable Access

Template variables are passed via the C<$v> object, which supports both
method-style and hash-style access:

    # Method syntax (recommended) - throws error on missing keys
    <%= $v->title %>
    <%= $v->user->name %>

    # Hash syntax - returns undef for missing keys (faster in tight loops)
    <%= $v->{title} %>
    <% for my $item (@{$v->{items}}) { %>
        <%= $item->{name} %>
    <% } %>

The method syntax catches typos at runtime - if you access a variable that
wasn't passed to the template, you get a helpful error listing available
variables. For performance-critical loops, hash access has slightly lower
overhead.

Example:

    <ul>
      <% for my $item (@{$v->{items}}) { %>
        <li><%= $item->{name} %></li>
      <% } %>
    </ul>

=head2 UTF-8 Support

Templates and output are fully UTF-8 aware:

=over 4

=item * Save template files as UTF-8 (they can contain any Unicode characters)

=item * Use C<use utf8;> in your app if it contains UTF-8 string literals

=item * C<< $c->render() >> automatically encodes output to UTF-8 bytes and
sets C<Content-Type: text/html; charset=utf-8>

=back

Example with Unicode:

    # In app.pl
    use utf8;
    $c->render('index', message => 'Hello λ 🔥 中文!');

    # In template (index.html.ep)
    <p><%= $v->message %> ♥</p>

=head1 LAYOUT SYSTEM

Templates can extend layouts:

    <!-- templates/layouts/default.html.ep -->
    <!DOCTYPE html>
    <html>
    <head><title><%= $v->title %></title></head>
    <body>
      <%= content() %>
    </body>
    </html>

    <!-- templates/index.html.ep -->
    <% extends('layouts/default') %>

    <h1>Welcome to <%= $v->title %></h1>

Variables passed to C<render()> are available in both the page template
and the layout via the C<$v> object.

=head2 Nested Layouts

Layouts can extend other layouts, enabling composition patterns like
admin sections with their own chrome:

    <!-- templates/layouts/base.html.ep -->
    <!DOCTYPE html>
    <html>
    <head><title><%= $v->{title} %></title></head>
    <body class="base"><%= content() %></body>
    </html>

    <!-- templates/layouts/admin.html.ep -->
    <% extends('layouts/base', title => $v->{title}) %>
    <div class="admin-wrapper">
      <nav>Admin Menu</nav>
      <%= content() %>
    </div>

    <!-- templates/admin/dashboard.html.ep -->
    <% extends('layouts/admin', title => 'Dashboard') %>
    <h1>Admin Dashboard</h1>

The rendering chain is: dashboard -> admin layout -> base layout.
Each layout wraps the content from the previous level.

=head2 Named Content Blocks

Use C<content_for()> to inject content into specific slots in layouts:

    <!-- templates/layouts/default.html.ep -->
    <html>
    <head>
      <%= content('styles') %>
    </head>
    <body>
      <%= content() %>
      <%= content('scripts') %>
    </body>
    </html>

    <!-- templates/page.html.ep -->
    <% extends('layouts/default') %>
    <% content_for('styles', '<link rel="stylesheet" href="page.css">') %>
    <% content_for('scripts', '<script src="page.js"></script>') %>
    <main>Page content here</main>

=head2 Partials and content_for

Partials can contribute to C<content_for()> blocks. When a page includes
multiple partials, each can add its own scripts or styles:

    <!-- templates/_comment.html.ep -->
    <% content_for('scripts', '<script src="comment-widget.js"></script>') %>
    <div class="comment"><%= $v->{text} %></div>

    <!-- templates/post.html.ep -->
    <% extends('layouts/default') %>
    <% for my $comment (@{$v->{comments}}) { %>
      <%= include('_comment', text => $comment) %>
    <% } %>

All C<content_for()> calls accumulate, so the layout receives scripts
from every partial that was included.

=head1 TEMPLATE HELPERS

The following helpers are available in all templates:

=head2 Layout Helpers

=head3 extends

    <% extends('layouts/default') %>

Specify a layout template to wrap the current template. The layout will
receive all variables passed to the page template. Should be called at the
top of a template.

=head3 content

    # In layout - output the main body content
    <%= content() %>

    # In layout - output a named block
    <%= content('scripts') %>

Retrieve and output content. With no arguments, returns the main body content
from the child template. With a name argument, returns the named content block.

=head3 content_for

    # In page template - define a named block (string)
    <% content_for('scripts', '<script src="app.js"></script>') %>

    # Or use block syntax for multi-line content
    <% content_for('scripts', sub { %>
      <script src="app.js"></script>
      <script>initApp();</script>
    <% }) %>

Define named content blocks. Useful for injecting content into specific parts
of a layout (e.g., extra scripts, styles, or sidebar content). Content is
accumulated, so multiple calls will append. Use C<< <%= content('name') %> >>
in the layout to output the block.

=head3 block

    # String syntax
    <% block('sidebar', '<nav>...</nav>') %>

    # Block syntax for multi-line content
    <% block('sidebar', sub { %>
      <nav>
        <a href="/">Home</a>
        <a href="/about">About</a>
      </nav>
    <% }) %>

Set a named content block (replaces any existing content, unlike C<content_for>
which appends).

=head3 capture

    <% my $card = capture(sub { %>
      <div class="card">
        <h2><%= $v->title %></h2>
        <p><%= $v->body %></p>
      </div>
    <% }); %>

    <!-- Use captured content multiple times -->
    <%= raw($card) %>
    <%= raw($card) %>

Capture template content into a variable for later reuse. Returns a string
that can be output with C<raw()> (since it's already rendered HTML).

=head2 Partial/Include Helper

=head3 include

    <%= include('partials/header', title => 'My Page') %>
    <%= include('todos/_item', todo => $todo) %>

Render a partial template and insert its output. Variables can be passed
to the partial. Partial filenames can optionally start with underscore
(Rails convention) - the view will find C<_item.html.ep> if C<item> is
requested.

=head2 Escaping Helpers

These helpers come from L<Template::EmbeddedPerl> and control HTML escaping:

=head3 raw

    <%= raw('<b>Already safe HTML</b>') %>

Output a string without escaping. Use for trusted HTML content.
B<Warning:> Never use with user input without sanitization.

=head3 safe

    <%= safe($user_input) %>

Escape HTML entities and mark as safe (won't be double-escaped).
Converts C<< < >> to C<< &lt; >>, C<< > >> to C<< &gt; >>, etc.

=head3 safe_concat

    <%= safe_concat('<div>', $content, '</div>') %>

Concatenate multiple strings, escaping each one, and return as safe.

=head2 URL/String Helpers

=head3 url_encode

    <a href="/search?q=<%= url_encode($query) %>">Search</a>

URL-encode a string for use in query parameters.

=head3 escape_javascript

    <script>var name = '<%= escape_javascript($name) %>';</script>

Escape a string for safe inclusion in JavaScript. Escapes quotes,
backslashes, and newlines.

=head3 trim

    <%= trim('  hello  ') %>

Remove leading and trailing whitespace from a string.

=head3 mtrim

    <%= mtrim("  line1  \n  line2  ") %>

Trim whitespace from each line in a multiline string.

=head2 Routing Helper

=head3 route

    <a href="<%= route('user_profile', id => 42) %>">Profile</a>

Generate a URL for a named route. Only available if the view is connected
to a PAGI::Simple app with named routes configured.

=head1 SEE ALSO

L<PAGI::Simple>, L<Template::EmbeddedPerl>

=head1 AUTHOR

PAGI Contributors

=cut

1;
