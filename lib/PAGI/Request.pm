package PAGI::Request;
use strict;
use warnings;
use Hash::MultiValue;
use Encode qw(decode FB_CROAK FB_DEFAULT LEAVE_SRC);
use Cookie::Baker qw(crush_cookie);
use MIME::Base64 qw(decode_base64);
use Future::AsyncAwait;
use JSON::MaybeXS qw(decode_json);
use Carp qw(croak);
use PAGI::Request::MultiPartHandler;
use PAGI::Request::Upload;
use PAGI::Request::Negotiate;
use PAGI::Request::BodyStream;

# Class-level configuration defaults
our %CONFIG = (
    max_body_size     => 10 * 1024 * 1024,   # 10MB total request body
    max_field_size    => 1 * 1024 * 1024,    # 1MB per form field (non-file)
    max_file_size     => 10 * 1024 * 1024,   # 10MB per file upload
    max_files         => 20,
    max_fields        => 1000,
    path_param_strict => 0,                  # Die if path_params not in scope
    spool_threshold => 64 * 1024,           # 64KB
    temp_dir        => $ENV{TMPDIR} // '/tmp',
);

sub configure {
    my ($class, %opts) = @_;
    for my $key (keys %opts) {
        $CONFIG{$key} = $opts{$key} if exists $CONFIG{$key};
    }
}

sub config {
    my $class = shift;
    return \%CONFIG;
}

sub new {
    my ($class, $scope, $receive) = @_;
    return bless {
        scope   => $scope,
        receive => $receive,
    }, $class;
}

# Basic properties from scope
sub method       { shift->{scope}{method} }
sub path         { shift->{scope}{path} }
sub raw_path     { my $s = shift; $s->{scope}{raw_path} // $s->{scope}{path} }
sub query_string { shift->{scope}{query_string} // '' }
sub scheme       { shift->{scope}{scheme} // 'http' }
sub http_version { shift->{scope}{http_version} // '1.1' }
sub client       { shift->{scope}{client} }
sub raw          { shift->{scope} }

# Internal: URL decode a string (handles + as space)
sub _url_decode {
    my ($str) = @_;
    return '' unless defined $str;
    $str =~ s/\+/ /g;
    $str =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
    return $str;
}

# Internal: Decode UTF-8 with replacement or croak in strict mode
sub _decode_utf8 {
    my ($str, $strict) = @_;
    return '' unless defined $str;
    my $flag = $strict ? FB_CROAK : FB_DEFAULT;
    $flag |= LEAVE_SRC;
    return decode('UTF-8', $str, $flag);
}

# Host from headers
sub host {
    my $self = shift;
    return $self->header('host');
}

# Content-Type shortcut
sub content_type {
    my $self = shift;
    my $ct = $self->header('content-type') // '';
    # Strip parameters like charset
    $ct =~ s/;.*//;
    return $ct;
}

# Content-Length shortcut
sub content_length {
    my $self = shift;
    return $self->header('content-length');
}

# Single header lookup (case-insensitive, returns last value)
sub header {
    my ($self, $name) = @_;
    $name = lc($name);
    my $value;
    for my $pair (@{$self->{scope}{headers} // []}) {
        if (lc($pair->[0]) eq $name) {
            $value = $pair->[1];
        }
    }
    return $value;
}

# All headers as Hash::MultiValue (cached in scope, case-insensitive keys)
sub headers {
    my $self = shift;
    return $self->{scope}{'pagi.request.headers'} if $self->{scope}{'pagi.request.headers'};

    my @pairs;
    for my $pair (@{$self->{scope}{headers} // []}) {
        push @pairs, lc($pair->[0]), $pair->[1];
    }

    $self->{scope}{'pagi.request.headers'} = Hash::MultiValue->new(@pairs);
    return $self->{scope}{'pagi.request.headers'};
}

# All values for a header
sub header_all {
    my ($self, $name) = @_;
    return $self->headers->get_all(lc($name));
}

# Query params as Hash::MultiValue (cached in scope)
# Options: strict => 1 (croak on invalid UTF-8), raw => 1 (skip UTF-8 decoding)
sub query_params {
    my ($self, %opts) = @_;
    my $strict = delete $opts{strict} // 0;
    my $raw    = delete $opts{raw}    // 0;
    croak("Unknown options to query_params: " . join(', ', keys %opts)) if %opts;

    my $cache_key = $raw ? 'pagi.request.query.raw' : ($strict ? 'pagi.request.query.strict' : 'pagi.request.query');
    return $self->{scope}{$cache_key} if $self->{scope}{$cache_key};

    my $qs = $self->query_string;
    my @pairs;

    for my $part (split /[&;]/, $qs) {
        next unless length $part;
        my ($key, $val) = split /=/, $part, 2;
        $key //= '';
        $val //= '';

        # URL decode (handles + as space)
        my $key_decoded = _url_decode($key);
        my $val_decoded = _url_decode($val);

        # UTF-8 decode unless raw mode
        my $key_final = $raw ? $key_decoded : _decode_utf8($key_decoded, $strict);
        my $val_final = $raw ? $val_decoded : _decode_utf8($val_decoded, $strict);

        push @pairs, $key_final, $val_final;
    }

    $self->{scope}{$cache_key} = Hash::MultiValue->new(@pairs);
    return $self->{scope}{$cache_key};
}

# Raw query params (no UTF-8 decoding)
sub raw_query_params {
    my $self = shift;
    return $self->query_params(raw => 1);
}

# Shortcut for single query param
sub query {
    my ($self, $name, %opts) = @_;
    return $self->query_params(%opts)->get($name);
}

# Raw single query param
sub raw_query {
    my ($self, $name) = @_;
    return $self->query($name, raw => 1);
}

# All cookies as hashref (cached in scope)
sub cookies {
    my $self = shift;
    return $self->{scope}{'pagi.request.cookies'} if exists $self->{scope}{'pagi.request.cookies'};

    my $cookie_header = $self->header('cookie') // '';
    $self->{scope}{'pagi.request.cookies'} = crush_cookie($cookie_header);
    return $self->{scope}{'pagi.request.cookies'};
}

# Single cookie value
sub cookie {
    my ($self, $name) = @_;
    return $self->cookies->{$name};
}

# Method predicates
sub is_get     { uc(shift->method // '') eq 'GET' }
sub is_post    { uc(shift->method // '') eq 'POST' }
sub is_put     { uc(shift->method // '') eq 'PUT' }
sub is_patch   { uc(shift->method // '') eq 'PATCH' }
sub is_delete  { uc(shift->method // '') eq 'DELETE' }
sub is_head    { uc(shift->method // '') eq 'HEAD' }
sub is_options { uc(shift->method // '') eq 'OPTIONS' }

# =============================================================================
# Connection State Methods (PAGI spec 0.3)
#
# These methods provide non-destructive disconnect detection via the
# pagi.connection scope key, which is a PAGI::Server::ConnectionState object.
# =============================================================================

# Get the connection state object
sub connection {
    my $self = shift;
    return $self->{scope}{'pagi.connection'};
}

# Check if client is still connected (synchronous, non-destructive)
sub is_connected {
    my $self = shift;
    my $conn = $self->connection;
    return 0 unless $conn;
    return $conn->is_connected;
}

# Check if client has disconnected (synchronous, non-destructive)
# This is the inverse of is_connected - preferred for new code
sub is_disconnected {
    my $self = shift;
    return !$self->is_connected;
}

# Get the disconnect reason string, or undef if still connected
sub disconnect_reason {
    my $self = shift;
    my $conn = $self->connection;
    return undef unless $conn;
    return $conn->disconnect_reason;
}

# Register a callback to be invoked when disconnect occurs
sub on_disconnect {
    my ($self, $cb) = @_;
    my $conn = $self->connection;
    return unless $conn;
    $conn->on_disconnect($cb);
}

# Get a Future that resolves when the client disconnects
sub disconnect_future {
    my $self = shift;
    my $conn = $self->connection;
    return undef unless $conn;
    return $conn->disconnect_future;
}

# Content-type predicates
sub is_json {
    my $self = shift;
    my $ct = $self->content_type;
    return $ct eq 'application/json';
}

sub is_form {
    my $self = shift;
    my $ct = $self->content_type;
    return $ct eq 'application/x-www-form-urlencoded'
        || $ct =~ m{^multipart/form-data};
}

sub is_multipart {
    my $self = shift;
    my $ct = $self->content_type;
    return $ct =~ m{^multipart/form-data};
}

# Accept header check using Negotiate module
# Combines multiple Accept headers per RFC 7230 Section 3.2.2
sub accepts {
    my ($self, $mime_type) = @_;
    my @accept_values = $self->header_all('accept');
    my $accept = join(', ', @accept_values);
    return PAGI::Request::Negotiate->accepts_type($accept, $mime_type);
}

# Find best matching content type from supported list
# Combines multiple Accept headers per RFC 7230 Section 3.2.2
sub preferred_type {
    my ($self, @types) = @_;
    my @accept_values = $self->header_all('accept');
    my $accept = join(', ', @accept_values);
    return PAGI::Request::Negotiate->best_match(\@types, $accept);
}

# Extract Bearer token from Authorization header
sub bearer_token {
    my $self = shift;
    my $auth = $self->header('authorization') // '';
    if ($auth =~ /^Bearer\s+(.+)$/i) {
        return $1;
    }
    return undef;
}

# Extract Basic auth credentials
sub basic_auth {
    my $self = shift;
    my $auth = $self->header('authorization') // '';
    if ($auth =~ /^Basic\s+(.+)$/i) {
        my $decoded = decode_base64($1);
        my ($user, $pass) = split /:/, $decoded, 2;
        return ($user, $pass);
    }
    return (undef, undef);
}

# Path parameters - captured from URL path by router
# Stored in scope->{path_params} for router-agnostic access
sub path_params {
    my $self = shift;
    my $params = $self->{scope}{path_params};
    if (!defined $params && $CONFIG{path_param_strict}) {
        croak "path_params not set in scope (no router configured?). "
            . "Set PAGI::Request->configure(path_param_strict => 0) to allow this.";
    }
    return $params // {};
}

sub path_param {
    my ($self, $name) = @_;
    my $params = $self->{scope}{path_params};
    if (!defined $params && $CONFIG{path_param_strict}) {
        croak "path_params not set in scope (no router configured?). "
            . "Set PAGI::Request->configure(path_param_strict => 0) to allow this.";
    }
    return ($params // {})->{$name};
}

# Per-request storage - lives in scope, shared across Request/Response/WebSocket/SSE
#
# DESIGN NOTE: Stash is intentionally scope-based, not object-based. When middleware
# creates a shallow copy of scope ({ %$scope, key => val }), the inner 'pagi.stash'
# hashref is preserved by reference. This means:
#   1. All Request/Response objects created from the same scope chain share stash
#   2. Middleware modifications to stash are visible to downstream handlers
#   3. The stash "transcends" the middleware chain via scope, not via object identity
#
# This addresses a potential concern about Request objects being ephemeral - stash
# works correctly because it lives in scope, which IS shared across the chain.
sub stash {
    my $self = shift;
    return $self->{scope}{'pagi.stash'} //= {};
}

# Application state (injected by PAGI::Lifespan, read-only)
sub state {
    my $self = shift;
    return $self->{scope}{state} // {};
}

# Body streaming - mutually exclusive with buffered body methods
sub body_stream {
    my ($self, %opts) = @_;

    croak "Body already consumed; streaming not available" if $self->{scope}{'pagi.request.body.read'};
    croak "Body streaming already started" if $self->{scope}{'pagi.request.body.stream.created'};

    $self->{scope}{'pagi.request.body.stream.created'} = 1;

    my $max_bytes = $opts{max_bytes};
    my $limit_name = defined $max_bytes ? 'max_bytes' : undef;
    if (!defined $max_bytes) {
        my $cl = $self->content_length;
        if (defined $cl) {
            $max_bytes = $cl;
            $limit_name = 'content-length';
        }
    }

    return PAGI::Request::BodyStream->new(
        receive    => $self->{receive},
        max_bytes  => $max_bytes,
        limit_name => $limit_name,
        decode     => $opts{decode},
        strict     => $opts{strict},
    );
}

# Read raw body bytes (async, cached in scope)
async sub body {
    my $self = shift;

    croak "Body streaming already started; buffered helpers unavailable"
        if $self->{scope}{'pagi.request.body.stream.created'};

    # Return cached body if already read
    return $self->{scope}{'pagi.request.body'} if $self->{scope}{'pagi.request.body.read'};

    my $receive = $self->{receive};
    die "No receive callback provided" unless $receive;

    my $body = '';
    while (1) {
        my $message = await $receive->();
        last unless $message && $message->{type};
        last if $message->{type} eq 'http.disconnect';

        $body .= $message->{body} // '';
        last unless $message->{more};
    }

    $self->{scope}{'pagi.request.body'} = $body;
    $self->{scope}{'pagi.request.body.read'} = 1;
    return $body;
}

# Read body as decoded UTF-8 text (async)
# Options: strict => 1 (croak on invalid UTF-8)
async sub text {
    my ($self, %opts) = @_;
    my $strict = delete $opts{strict} // 0;
    croak("Unknown options to text: " . join(', ', keys %opts)) if %opts;

    my $body = await $self->body;
    return _decode_utf8($body, $strict);
}

# Parse body as JSON (async, dies on error)
async sub json {
    my $self = shift;
    my $body = await $self->body;
    return decode_json($body);
}

# Parse URL-encoded form body (async, returns Hash::MultiValue, cached in scope)
# Options: strict => 1 (croak on invalid UTF-8), raw => 1 (skip UTF-8 decoding)
async sub form {
    my ($self, %opts) = @_;
    my $strict = delete $opts{strict} // 0;
    my $raw    = delete $opts{raw}    // 0;

    # Extract multipart options before checking for unknown opts
    my %multipart_opts;
    for my $key (qw(max_field_size max_file_size spool_threshold max_files max_fields temp_dir)) {
        $multipart_opts{$key} = delete $opts{$key} if exists $opts{$key};
    }
    croak("Unknown options to form: " . join(', ', keys %opts)) if %opts;

    my $cache_key = $raw ? 'pagi.request.form.raw' : ($strict ? 'pagi.request.form.strict' : 'pagi.request.form');

    # Return cached if available
    return $self->{scope}{$cache_key} if $self->{scope}{$cache_key};

    # For multipart, delegate to uploads handling
    if ($self->is_multipart) {
        # Multipart always parses to default cache, then copy
        my $form = await $self->_parse_multipart_form(%multipart_opts);
        $self->{scope}{$cache_key} = $form;
        return $form;
    }

    # URL-encoded form
    my $body = await $self->body;
    my @pairs;

    for my $part (split /[&;]/, $body) {
        next unless length $part;
        my ($key, $val) = split /=/, $part, 2;
        $key //= '';
        $val //= '';

        # URL decode (handles + as space)
        my $key_decoded = _url_decode($key);
        my $val_decoded = _url_decode($val);

        # UTF-8 decode unless raw mode
        my $key_final = $raw ? $key_decoded : _decode_utf8($key_decoded, $strict);
        my $val_final = $raw ? $val_decoded : _decode_utf8($val_decoded, $strict);

        push @pairs, $key_final, $val_final;
    }

    $self->{scope}{$cache_key} = Hash::MultiValue->new(@pairs);
    return $self->{scope}{$cache_key};
}

# Raw form params (no UTF-8 decoding)
async sub raw_form {
    my ($self, %opts) = @_;
    return await $self->form(%opts, raw => 1);
}

# Parse multipart form (internal, cached in scope)
async sub _parse_multipart_form {
    my ($self, %opts) = @_;

    # Already parsed?
    return $self->{scope}{'pagi.request.form'}
        if $self->{scope}{'pagi.request.form'} && $self->{scope}{'pagi.request.uploads'};

    # Extract boundary from content-type
    my $ct = $self->header('content-type') // '';
    my ($boundary) = $ct =~ /boundary=([^;\s]+)/;
    $boundary =~ s/^["']|["']$//g if $boundary;  # Strip quotes

    die "No boundary found in Content-Type" unless $boundary;

    my $handler = PAGI::Request::MultiPartHandler->new(
        boundary        => $boundary,
        receive         => $self->{receive},
        max_field_size  => $opts{max_field_size},
        max_file_size   => $opts{max_file_size},
        spool_threshold => $opts{spool_threshold},
        max_files       => $opts{max_files},
        max_fields      => $opts{max_fields},
        temp_dir        => $opts{temp_dir},
    );

    my ($form, $uploads) = await $handler->parse;

    $self->{scope}{'pagi.request.form'} = $form;
    $self->{scope}{'pagi.request.uploads'} = $uploads;
    $self->{scope}{'pagi.request.body.read'} = 1;  # Body has been consumed

    return $form;
}

# Get all uploads as Hash::MultiValue (cached in scope)
async sub uploads {
    my ($self, %opts) = @_;

    return $self->{scope}{'pagi.request.uploads'} if $self->{scope}{'pagi.request.uploads'};

    if ($self->is_multipart) {
        await $self->_parse_multipart_form(%opts);
        return $self->{scope}{'pagi.request.uploads'};
    }

    # Not multipart - return empty
    $self->{scope}{'pagi.request.uploads'} = Hash::MultiValue->new();
    return $self->{scope}{'pagi.request.uploads'};
}

# Get single upload by field name
async sub upload {
    my ($self, $name, %opts) = @_;
    my $uploads = await $self->uploads(%opts);
    return $uploads->get($name);
}

# Get all uploads for a field name
async sub upload_all {
    my ($self, $name, %opts) = @_;
    my $uploads = await $self->uploads(%opts);
    return $uploads->get_all($name);
}

1;

__END__

=head1 NAME

PAGI::Request - Convenience wrapper for PAGI request scope

=head1 SYNOPSIS

    use PAGI::Request;
    use Future::AsyncAwait;

    async sub app {
        my ($scope, $receive, $send) = @_;
        my $req = PAGI::Request->new($scope, $receive);

        # Basic properties
        my $method = $req->method;        # GET, POST, etc.
        my $path   = $req->path;          # /users/42
        my $host   = $req->host;          # example.com

        # Query parameters (Hash::MultiValue)
        my $page = $req->query('page');
        my @tags = $req->query_params->get_all('tags');

        # Headers
        my $ct = $req->content_type;
        my $auth = $req->header('authorization');

        # Cookies
        my $session = $req->cookie('session');

        # Body parsing (async)
        my $json = await $req->json;      # Parse JSON body
        my $form = await $req->form;      # Parse form data

        # File uploads
        my $avatar = await $req->upload('avatar');
        if ($avatar && !$avatar->is_empty) {
            $avatar->move_to('/uploads/avatar.jpg');  # blocking I/O
        }

        # Streaming large bodies
        my $stream = $req->body_stream(max_bytes => 100 * 1024 * 1024);
        await $stream->stream_to_file('/uploads/large.bin');

        # Auth helpers
        my $token = $req->bearer_token;
        my ($user, $pass) = $req->basic_auth;

        # Per-request storage
        $req->stash->{user} = $current_user;
    }

=head1 DESCRIPTION

PAGI::Request provides a friendly interface to PAGI request data. It wraps
the raw C<$scope> hashref and C<$receive> callback with convenient methods
for accessing headers, query parameters, cookies, request body, and file
uploads.

This is an optional convenience layer. Raw PAGI applications continue to
work with C<$scope> and C<$receive> directly.

=head1 CLASS METHODS

=head2 configure

    PAGI::Request->configure(
        max_body_size     => 10 * 1024 * 1024,  # 10MB total body
        max_field_size    => 1 * 1024 * 1024,   # 1MB per form field
        max_file_size     => 10 * 1024 * 1024,  # 10MB per file upload
        spool_threshold   => 64 * 1024,         # 64KB
        path_param_strict => 0,                 # Die if path_params not in scope
    );

Set class-level defaults for body/upload handling and path parameters.

=over 4

=item max_body_size

Maximum total request body size. Enforced by the server.

=item max_field_size

Maximum size for non-file form fields in multipart requests. Default: 1MB.
Protects against oversized text submissions.

=item max_file_size

Maximum size for file uploads in multipart requests. Default: 10MB.
Applies to parts with a filename in Content-Disposition.

=item spool_threshold

Size at which multipart data is spooled to disk. Default: 64KB.

=item path_param_strict

When set to 1, C<path_params> and C<path_param> will die if
C<< $scope->{path_params} >> is not defined (i.e., no router has set it).
Default: 0 (return empty hashref/undef silently).

This is useful for catching configuration errors where you expect a router
but one isn't configured. See L</Strict Mode> for details.

=back

=head2 config

    my $config = PAGI::Request->config;

Returns the current configuration hashref.

=head1 CONSTRUCTOR

=head2 new

    my $req = PAGI::Request->new($scope, $receive);

Creates a new request object. C<$scope> is required. C<$receive> is optional
but required for body/upload methods.

=head1 PROPERTIES

=head2 method

HTTP method (GET, POST, PUT, etc.)

=head2 path

Request path, UTF-8 decoded.

=head2 raw_path

Request path as raw bytes (percent-encoded).

=head2 query_string

Raw query string (without leading ?).

=head2 scheme

C<http> or C<https>.

=head2 host

Host from the Host header.

=head2 http_version

HTTP version (1.0 or 1.1).

=head2 client

Arrayref of C<[host, port]> or undef.

=head2 content_type

Content-Type header value (without parameters).

=head2 content_length

Content-Length header value.

=head2 raw

Returns the raw scope hashref.

=head1 HEADER METHODS

=head2 header

    my $value = $req->header('Content-Type');

Get a single header value (case-insensitive). Returns the last value if
the header appears multiple times.

=head2 header_all

    my @values = $req->header_all('Accept');

Get all values for a header.

=head2 headers

    my $headers = $req->headers;  # Hash::MultiValue

Get all headers as a L<Hash::MultiValue> object.

=head1 QUERY PARAMETERS

=head2 query_params

    my $params = $req->query_params;  # Hash::MultiValue

Get query parameters as L<Hash::MultiValue>.

=head2 query

    my $value = $req->query('page');

Shortcut for C<< $req->query_params->get($name) >>.

=head1 PATH PARAMETERS

Path parameters are captured from the URL path by a router (e.g., L<PAGI::App::Router>)
and stored in C<< $scope->{path_params} >>. This is a router-agnostic interface -
any router can populate this field.

=head2 path_params

    my $params = $req->path_params;  # hashref

Get all path parameters as a hashref. Returns an empty hashref if no router
has set path parameters.

    # Route: /users/:id/posts/:post_id
    # URL: /users/42/posts/100
    my $params = $req->path_params;
    # { id => '42', post_id => '100' }

=head2 path_param

    my $id = $req->path_param('id');

Get a single path parameter by name. Returns C<undef> if not found.

    # Route: /users/:id
    # URL: /users/42
    my $id = $req->path_param('id');  # '42'

=head2 Strict Mode

By default, C<path_params> and C<path_param> return empty values if no router
has set C<< $scope->{path_params} >>. This is the safest behavior for middleware
and handlers that may run with or without a router.

If you want to catch configuration errors early, enable strict mode:

    PAGI::Request->configure(path_param_strict => 1);

With strict mode enabled, calling C<path_params> or C<path_param> when
C<< $scope->{path_params} >> is undefined will die with an error message.
This helps catch bugs where you expect a router but one isn't configured.

    # Strict mode: dies if no router set path_params
    PAGI::Request->configure(path_param_strict => 1);

    my $id = $req->path_param('id');
    # Dies: "path_params not set in scope (no router configured?)"

The default is C<path_param_strict =E<gt> 0> (non-strict), which matches
Starlette's behavior of returning an empty dict when path_params is not set.

=head1 COOKIES

=head2 cookies

    my $cookies = $req->cookies;  # hashref

Get all cookies.

=head2 cookie

    my $session = $req->cookie('session');

Get a single cookie value.

=head1 BODY METHODS (ASYNC)

=head2 body_stream

    my $stream = $req->body_stream;
    my $stream = $req->body_stream(
        max_bytes => 10 * 1024 * 1024,  # 10MB limit
        decode    => 'UTF-8',            # Decode to UTF-8
        strict    => 1,                  # Strict UTF-8 decoding
    );

Returns a L<PAGI::Request::BodyStream> for streaming body consumption. This is
useful for processing large request bodies incrementally without loading them
entirely into memory.

B<Options:>

=over 4

=item * C<max_bytes> - Maximum body size. Defaults to Content-Length header if present.

=item * C<decode> - Encoding to decode chunks to (typically 'UTF-8').

=item * C<strict> - If true, throw on invalid UTF-8. Default: false (use replacement chars).

=back

B<Important:> Body streaming is mutually exclusive with buffered body methods
(C<body>, C<text>, C<json>, C<form>). Once you start streaming, you cannot use
those methods, and vice versa.

Example:

    # Stream large upload to file
    my $stream = $req->body_stream(max_bytes => 100 * 1024 * 1024);
    await $stream->stream_to_file('/uploads/data.bin');

See L<PAGI::Request::BodyStream> for full documentation.

=head2 body

    my $bytes = await $req->body;

Read raw body bytes. Cached after first read.

B<Important:> Cannot be used after C<body_stream()> has been called.

=head2 text

    my $text = await $req->text;

Read body as UTF-8 decoded text.

=head2 json

    my $data = await $req->json;

Parse body as JSON. Dies on parse error.

=head2 form

    my $form = await $req->form;  # Hash::MultiValue

Parse URL-encoded or multipart form data.

=head1 UPLOAD METHODS (ASYNC)

=head2 uploads

    my $uploads = await $req->uploads;  # Hash::MultiValue

Get all uploads as L<Hash::MultiValue> of L<PAGI::Request::Upload> objects.

=head2 upload

    my $file = await $req->upload('avatar');

Get a single upload by field name.

=head2 upload_all

    my @files = await $req->upload_all('photos');

Get all uploads for a field name.

=head1 PREDICATES

=head2 is_get, is_post, is_put, is_patch, is_delete, is_head, is_options

    if ($req->is_post) { ... }

Check HTTP method.

=head2 is_json

True if Content-Type is C<application/json>.

=head2 is_form

True if Content-Type is form-urlencoded or multipart.

=head2 is_multipart

True if Content-Type is C<multipart/form-data>.

=head2 accepts

    if ($req->accepts('text/html')) { ... }
    if ($req->accepts('json')) { ... }

Check Accept header (supports wildcards and shortcuts). Returns true if the
client accepts the given MIME type.

=head2 preferred_type

    my $type = $req->preferred_type('json', 'html', 'xml');

Returns the best matching content type from the provided list based on the
client's Accept header and quality values. Returns undef if none are acceptable.
Supports shortcuts (json, html, xml, etc).

=head1 CONNECTION STATE METHODS

These methods provide non-destructive disconnect detection. Unlike reading
from the receive queue, these methods do not consume any messages.

See L<PAGI::Server::ConnectionState> for the underlying implementation.

=head2 connection

    my $conn = $req->connection;

Returns the L<PAGI::Server::ConnectionState> object for this request, or
C<undef> if not provided by the server.

=head2 is_connected

    if ($req->is_connected) {
        # Client still connected
    }

Returns true if the client connection is still alive. This is a synchronous,
non-destructive check that does not consume messages from the receive queue.

=head2 is_disconnected

    if ($req->is_disconnected) {
        # Client has disconnected
    }

Returns true if the client has disconnected. Equivalent to
C<< !$req->is_connected >>.

This is a synchronous, non-destructive check.

=head2 disconnect_reason

    my $reason = $req->disconnect_reason;

Returns the disconnect reason string, or C<undef> if still connected.

Standard reasons include: C<client_closed>, C<client_timeout>, C<idle_timeout>,
C<write_error>, C<read_error>, C<protocol_error>, C<server_shutdown>,
C<body_too_large>.

See L<PAGI::Server::ConnectionState/disconnect_reason> for the full list.

=head2 on_disconnect

    $req->on_disconnect(sub {
        my ($reason) = @_;
        cleanup_resources();
        log_info("Client disconnected: $reason");
    });

Registers a callback to be invoked when the client disconnects. Multiple
callbacks may be registered. If the client has already disconnected, the
callback is invoked immediately.

=head2 disconnect_future

    my $future = $req->disconnect_future;
    if ($future) {
        # Race against other operations
        await Future->wait_any($disconnect_future, $event_future);
    }

Returns a Future that resolves when the client disconnects, or C<undef>
if not supported. The Future resolves with the disconnect reason string.

This is useful for racing against other async operations.

=head1 AUTH HELPERS

=head2 bearer_token

    my $token = $req->bearer_token;

Extract Bearer token from Authorization header.

=head2 basic_auth

    my ($user, $pass) = $req->basic_auth;

Decode Basic auth credentials.

=head1 STASH

=head2 stash

    $req->stash->{user} = $current_user;
    my $user = $req->stash->{user};

Returns the per-request stash hashref for sharing data between middleware
and handlers. The stash is also accessible via C<< $res->stash >>,
C<< $ws->stash >>, and C<< $sse->stash >> for consistency.

=head3 How Stash Works

The stash lives in C<< $scope->{'pagi.stash'} >>, not in the Request object
itself. This is an important design choice:

=over 4

=item * B<Scope-based, not object-based> - Request/Response objects are
ephemeral (each middleware/handler may create its own), but stash persists
because it lives in scope.

=item * B<Survives shallow copies> - When middleware creates a modified scope
(C<< { %$scope, key => val } >>), the stash hashref is preserved by reference.
All objects in the chain see the same stash.

=item * B<Shared across the chain> - Middleware sets values, handlers read them,
subrouters inherit them. The stash "flows through" via scope sharing.

=back

=head3 Example

    # In auth middleware
    async sub require_auth {
        my ($self, $req, $res, $next) = @_;
        $req->stash->{user} = verify_token($req->bearer_token);
        await $next->();
    }

    # In handler - sees the user (even though it's a different $req object)
    async sub get_profile {
        my ($self, $req, $res) = @_;
        my $user = $req->stash->{user};  # Set by middleware
        await $res->json($user);
    }

    # Can also read via Response
    async sub another_handler {
        my ($self, $req, $res) = @_;
        my $user = $res->stash->{user};  # Same stash!
        await $res->json($user);
    }

B<Note:> For worker-level state (database connections, config), see
the C<state> method below.

=head2 state

    my $db = $req->state->{db};
    my $config = $req->state->{config};

Returns the application state hashref injected by L<PAGI::Lifespan>.
This contains worker-level shared state like database connections
and configuration. Returns empty hashref if no state was injected.

B<Key differences from stash:>

=over 4

=item * C<state> is read-only, set during lifespan startup

=item * C<state> is shared across all requests in a worker

=item * C<stash> is per-request, writable by middleware/handlers

=back

=head1 SEE ALSO

L<PAGI::Request::Upload>, L<PAGI::Request::BodyStream>, L<Hash::MultiValue>

=cut
