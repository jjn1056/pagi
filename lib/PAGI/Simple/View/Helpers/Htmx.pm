package PAGI::Simple::View::Helpers::Htmx;

use strict;
use warnings;
use experimental 'signatures';

our $VERSION = '0.01';

use JSON::MaybeXS qw(encode_json);
use Template::EmbeddedPerl::SafeString;

# Use Template::EmbeddedPerl's SafeString so auto-escaping recognizes our output
sub raw ($html) {
    return Template::EmbeddedPerl::SafeString::raw($html);
}

=head1 NAME

PAGI::Simple::View::Helpers::Htmx - htmx attribute helpers for PAGI::Simple templates

=head1 SYNOPSIS

    # In templates:
    <button <%= hx_delete('/items/123', target => '#item-123', confirm => 'Delete?') %>>
      Delete
    </button>

    # Include htmx script
    <%= htmx() %>
    <%= htmx_ws() %>
    <%= htmx_sse() %>

=head1 DESCRIPTION

This module provides template helpers for generating htmx attributes.
The helpers are automatically available in templates when using PAGI::Simple::View.

=head1 FUNCTIONS

=cut

=head2 get_helpers

    my $helpers = PAGI::Simple::View::Helpers::Htmx::get_helpers($view);

Returns a hashref of all htmx helper functions for use in templates.
This is called internally by PAGI::Simple::View.

B<Note:> The C<htmx()>, C<htmx_ws()>, and C<htmx_sse()> helpers require
C<< $app->share('htmx') >> to be called first. This ensures the htmx
JavaScript files are available at the paths the helpers expect.

=cut

sub get_helpers ($view = undef) {
    # Note: These helpers use $_current_view at render time (not the captured $view)
    # because templates may be cached and rendered with different view instances.
    return {
        htmx     => \&_htmx_script,
        htmx_ws  => \&_htmx_ws_script,
        htmx_sse => \&_htmx_sse_script,
        hx_get    => \&hx_get,
        hx_post   => \&hx_post,
        hx_put    => \&hx_put,
        hx_patch  => \&hx_patch,
        hx_delete => \&hx_delete,
        hx_sse    => \&hx_sse,
        hx_ws     => \&hx_ws,
    };
}

# Internal: Get current render context from PAGI::Simple::View during rendering
sub _get_current_render_context {
    return $PAGI::Simple::View::_current_render_context;
}

# Internal: Check if htmx has been shared, die with helpful message if not
sub _require_htmx_shared ($helper_name) {
    my $ctx = _get_current_render_context();
    return unless $ctx;  # Skip check if no context (standalone testing)

    my $app = $ctx->app;
    return unless $app;  # Skip check if no app

    unless ($app->has_shared('htmx')) {
        # Use Carp::croak for proper error location reporting
        require Carp;
        Carp::croak("$helper_name() requires \$app->share('htmx') to be called first");
    }
}

=head2 htmx

    <%= htmx() %>

Returns a script tag to include the htmx library.

B<Requires:> C<< $app->share('htmx') >> must be called first.

=cut

sub _htmx_script () {
    _require_htmx_shared('htmx');
    return raw('<script src="/static/htmx/htmx.min.js"></script>');
}

=head2 htmx_ws

    <%= htmx_ws() %>

Returns a script tag to include the htmx WebSocket extension.

B<Requires:> C<< $app->share('htmx') >> must be called first.

=cut

sub _htmx_ws_script () {
    _require_htmx_shared('htmx_ws');
    return raw('<script src="/static/htmx/ext/ws.js"></script>');
}

=head2 htmx_sse

    <%= htmx_sse() %>

Returns a script tag to include the htmx SSE extension.

B<Requires:> C<< $app->share('htmx') >> must be called first.

=cut

sub _htmx_sse_script () {
    _require_htmx_shared('htmx_sse');
    return raw('<script src="/static/htmx/ext/sse.js"></script>');
}

=head2 hx_get

    <%= hx_get($url, %options) %>

Generate hx-get and related attributes.

Options:

=over 4

=item * target - CSS selector for target element (hx-target)

=item * swap - Swap strategy (hx-swap): innerHTML, outerHTML, beforeend, etc.

=item * trigger - Event trigger (hx-trigger)

=item * confirm - Confirmation message (hx-confirm)

=item * push_url - Push URL to history (hx-push-url)

=item * select - CSS selector to select content from response (hx-select)

=item * vals - Additional values to include (hx-vals, serialized to JSON)

=item * headers - Additional headers (hx-headers, serialized to JSON)

=item * indicator - Element to show as loading indicator (hx-indicator)

=item * disabled_elt - Element(s) to disable during request (hx-disabled-elt)

=back

=cut

sub hx_get ($url, %opts) {
    return _build_hx_attrs('get', $url, %opts);
}

=head2 hx_post

    <%= hx_post($url, %options) %>

Generate hx-post and related attributes. Same options as hx_get.

=cut

sub hx_post ($url, %opts) {
    return _build_hx_attrs('post', $url, %opts);
}

=head2 hx_put

    <%= hx_put($url, %options) %>

Generate hx-put and related attributes. Same options as hx_get.

=cut

sub hx_put ($url, %opts) {
    return _build_hx_attrs('put', $url, %opts);
}

=head2 hx_patch

    <%= hx_patch($url, %options) %>

Generate hx-patch and related attributes. Same options as hx_get.

=cut

sub hx_patch ($url, %opts) {
    return _build_hx_attrs('patch', $url, %opts);
}

=head2 hx_delete

    <%= hx_delete($url, %options) %>

Generate hx-delete and related attributes. Same options as hx_get.

=cut

sub hx_delete ($url, %opts) {
    return _build_hx_attrs('delete', $url, %opts);
}

=head2 hx_sse

    <%= hx_sse($url, %options) %>

Generate SSE connection attributes.

Options:

=over 4

=item * connect - If true, adds hx-ext="sse" and sse-connect (default: 1)

=item * swap - SSE swap strategy (sse-swap)

=back

=cut

sub hx_sse ($url, %opts) {
    my @attrs;

    my $connect = $opts{connect} // 1;
    if ($connect) {
        push @attrs, 'hx-ext="sse"';
        push @attrs, qq{sse-connect="$url"};
    }

    if ($opts{swap}) {
        push @attrs, qq{sse-swap="$opts{swap}"};
    }

    return raw(join(' ', @attrs));
}

=head2 hx_ws

    <%= hx_ws($url, %options) %>

Generate WebSocket connection attributes.

Options:

=over 4

=item * connect - If true, adds hx-ext="ws" and ws-connect (default: 1)

=item * send - Selector for element that triggers send (ws-send)

=back

=cut

sub hx_ws ($url, %opts) {
    my @attrs;

    my $connect = $opts{connect} // 1;
    if ($connect) {
        push @attrs, 'hx-ext="ws"';
        push @attrs, qq{ws-connect="$url"};
    }

    if ($opts{send}) {
        push @attrs, qq{ws-send="$opts{send}"};
    }

    return raw(join(' ', @attrs));
}

# Internal: Build htmx attributes string
sub _build_hx_attrs ($method, $url, %opts) {
    my @attrs;

    # Main method attribute
    push @attrs, qq{hx-$method="$url"};

    # Target
    if (defined $opts{target}) {
        push @attrs, qq{hx-target="$opts{target}"};
    }

    # Swap strategy
    if (defined $opts{swap}) {
        push @attrs, qq{hx-swap="$opts{swap}"};
    }

    # Trigger
    if (defined $opts{trigger}) {
        push @attrs, qq{hx-trigger="$opts{trigger}"};
    }

    # Confirm dialog
    if (defined $opts{confirm}) {
        my $escaped = _escape_attr($opts{confirm});
        push @attrs, qq{hx-confirm="$escaped"};
    }

    # Push URL
    if ($opts{push_url}) {
        my $val = $opts{push_url} eq '1' || $opts{push_url} eq 1 ? 'true' : $opts{push_url};
        push @attrs, qq{hx-push-url="$val"};
    }

    # Select
    if (defined $opts{select}) {
        push @attrs, qq{hx-select="$opts{select}"};
    }

    # Values (JSON) - use single quotes to avoid escaping JSON double quotes
    if (defined $opts{vals} && ref($opts{vals}) eq 'HASH') {
        my $json = encode_json($opts{vals});
        push @attrs, qq{hx-vals='$json'};
    }

    # Headers (JSON) - use single quotes to avoid escaping JSON double quotes
    if (defined $opts{headers} && ref($opts{headers}) eq 'HASH') {
        my $json = encode_json($opts{headers});
        push @attrs, qq{hx-headers='$json'};
    }

    # Indicator
    if (defined $opts{indicator}) {
        push @attrs, qq{hx-indicator="$opts{indicator}"};
    }

    # Disabled element
    if (defined $opts{disabled_elt}) {
        push @attrs, qq{hx-disabled-elt="$opts{disabled_elt}"};
    }

    return raw(join(' ', @attrs));
}

# Internal: Escape attribute value
sub _escape_attr ($str) {
    return '' unless defined $str;
    $str =~ s/&/&amp;/g;
    $str =~ s/"/&quot;/g;
    $str =~ s/</&lt;/g;
    $str =~ s/>/&gt;/g;
    return $str;
}

=head1 SEE ALSO

L<PAGI::Simple::View>, L<htmx documentation|https://htmx.org/docs/>

=head1 AUTHOR

PAGI Contributors

=cut

1;
