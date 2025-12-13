package PAGI::Simple::View::RenderContext;

use strict;
use warnings;
use experimental 'signatures';

our $VERSION = '0.01';

use Carp qw(croak);
use Scalar::Util qw(blessed);

=head1 NAME

PAGI::Simple::View::RenderContext - Per-render state container for View

=head1 SYNOPSIS

    # Created internally by View->render()
    my $ctx = PAGI::Simple::View::RenderContext->new(
        view    => $view,
        context => $c,
    );

    $ctx->render('template', %vars);

=head1 DESCRIPTION

RenderContext holds per-render state (blocks, layout, form objects) separate
from the shared View configuration. This enables:

- Clean isolation between requests
- Nested rendering (components)
- Per-request Valiant form objects

=cut

sub new ($class, %args) {
    my $self = bless {
        view        => $args{view} // croak("view is required"),
        context     => $args{context},
        parent      => $args{parent},      # Parent RenderContext (for components)
        _blocks     => {},
        _layout     => undef,
        _layout_vars => {},
        _form       => undef,              # Lazy: Valiant form object
    }, $class;

    return $self;
}

=head2 view

    my $view = $ctx->view;

Returns the parent View object (shared config, template cache, helpers).

=cut

sub view ($self) { $self->{view} }

=head2 context

    my $c = $ctx->context;

Returns the PAGI::Simple::Context for this request.

=cut

sub context ($self) { $self->{context} }

=head2 parent

    my $parent_ctx = $ctx->parent;

Returns the parent RenderContext if this is a nested render (component).

=cut

sub parent ($self) { $self->{parent} }

=head2 app

    my $app = $ctx->app;

Returns the PAGI::Simple application instance.

=cut

sub app ($self) { $self->{view}->app }

=head2 blocks

    my $blocks = $ctx->blocks;
    $ctx->blocks->{name} = $content;

Returns the hashref of named content blocks.

=cut

sub blocks ($self) { $self->{_blocks} }

=head2 layout

    my $layout = $ctx->layout;
    $ctx->set_layout('layouts/default', %vars);

Get/set the current layout template name.

=cut

sub layout ($self) { $self->{_layout} }

sub set_layout ($self, $layout, %vars) {
    $self->{_layout} = $layout;
    $self->{_layout_vars} = \%vars;
}

sub layout_vars ($self) { $self->{_layout_vars} }

sub clear_layout ($self) {
    $self->{_layout} = undef;
    $self->{_layout_vars} = {};
}

=head2 render

    my $html = $ctx->render($template_name, %vars);

Render a template within this context.

=cut

sub render ($self, $template_name, %vars) {
    # Extract layout control option
    my $layout_override = delete $vars{layout};

    # Get compiled template from View
    my $template = $self->{view}->_get_template($template_name);

    # Render the template
    my $output = $template->render(\%vars);

    # Determine whether to use layout
    my $use_layout;
    if (defined $layout_override) {
        $use_layout = $layout_override ? 1 : 0;
    } else {
        # Auto-detect: skip layout for htmx requests (but not boosted)
        # Boosted requests (hx-boost links) expect full page with layout
        my $is_htmx = 0;
        my $is_boosted = 0;
        if ($self->{context} && $self->{context}->can('req')) {
            $is_htmx = $self->{context}->req->is_htmx;
            $is_boosted = $self->{context}->req->is_boosted;
        }
        $use_layout = !$is_htmx || $is_boosted;
    }

    # Render layout if set
    if ($self->{_layout} && $use_layout) {
        $output = $self->_render_layout($output, %vars);
    } else {
        # Trim leading whitespace for htmx partial responses
        # Template code blocks like <% my $x = 1; %>\n<div>... produce leading
        # newlines that break htmx outerHTML swaps (htmx sees text node first)
        $output =~ s/^\s+//;
    }

    return $output;
}

=head2 render_fragment

    my $html = $ctx->render_fragment($template_name, %vars);

Render a template as a fragment (without layout).

=cut

sub render_fragment ($self, $template_name, %vars) {
    my $template = $self->{view}->_get_template($template_name);
    my $output = $template->render(\%vars);
    # Trim leading whitespace - fragments are often used for htmx swaps
    $output =~ s/^\s+//;
    return $output;
}

=head2 include

    my $html = $ctx->include($partial_name, %vars);

Render a partial template.

=cut

sub include ($self, $partial_name, %vars) {
    my $template = $self->{view}->_get_template($partial_name);
    my $html = $template->render(\%vars);
    return Template::EmbeddedPerl::SafeString::raw($html);
}

# Internal: Render layout with content
sub _render_layout ($self, $content, %vars) {
    my $layout_name = $self->{_layout};
    my %layout_vars = %{$self->{_layout_vars}};

    # Store the content block
    $self->{_blocks}{content} = $content;

    # Reset layout tracking (layout may set its own extends)
    $self->{_layout} = undef;
    $self->{_layout_vars} = {};

    # Get and render layout
    my $template = $self->{view}->_get_template($layout_name);
    my %render_vars = (%vars, %layout_vars);
    my $output = $template->render(\%render_vars);

    # If layout called extends(), recurse
    if ($self->{_layout}) {
        $output = $self->_render_layout($output, %render_vars);
    }

    return $output;
}

=head1 VIEW INTERFACE METHODS

These methods implement the interface expected by Valiant::HTML::FormBuilder.

=head2 raw

    $ctx->raw($string);

Mark a string as safe (no escaping).

=cut

sub raw ($self, $string) {
    require Template::EmbeddedPerl::SafeString;
    return Template::EmbeddedPerl::SafeString::raw($string);
}

=head2 safe

    $ctx->safe($string);

Escape HTML and mark as safe.

=cut

sub safe ($self, $string) {
    require Template::EmbeddedPerl::SafeString;
    return Template::EmbeddedPerl::SafeString::safe($string);
}

=head2 safe_concat

    $ctx->safe_concat(@strings);

Concatenate strings, escaping as needed, return as safe.

=cut

sub safe_concat ($self, @strings) {
    require Template::EmbeddedPerl::SafeString;
    return Template::EmbeddedPerl::SafeString::safe_concat(@strings);
}

=head2 html_escape

    $ctx->html_escape($string);

Escape HTML entities in a string.

=cut

sub html_escape ($self, $string) {
    require Template::EmbeddedPerl::SafeString;
    return Template::EmbeddedPerl::SafeString::escape($string);
}

1;

=head1 SEE ALSO

L<PAGI::Simple::View>, L<PAGI::Simple::View::Role::Valiant>

=cut
