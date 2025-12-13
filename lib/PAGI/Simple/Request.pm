package PAGI::Simple::Request;

use strict;
use warnings;
use experimental 'signatures';

our $VERSION = '0.01';

use Hash::MultiValue;
use Future::AsyncAwait;
use JSON::MaybeXS ();
use Encode qw(decode FB_CROAK FB_DEFAULT LEAVE_SRC);
use Carp qw(croak);
use PAGI::Simple::CookieUtil;
use PAGI::Simple::Negotiate;
use PAGI::Simple::MultipartParser;
use PAGI::Simple::Upload;
use PAGI::Simple::BodyStream;

my $json = JSON::MaybeXS->new(utf8 => 1, allow_nonref => 1);

=head1 NAME

PAGI::Simple::Request - Request object for PAGI::Simple

=head1 SYNOPSIS

    # In a route handler:
    $app->get('/search' => sub ($c) {
        my $req = $c->req;

        my $method = $req->method;        # GET
        my $path   = $req->path;          # /search
        my $q      = $req->query_string;  # term=perl&page=1

        # Headers via Hash::MultiValue
        my $ct = $req->header('Content-Type');
        my $all_accepts = $req->headers->get_all('Accept');

        # Common header shortcuts
        my $content_type   = $req->content_type;
        my $content_length = $req->content_length;
    });

=head1 DESCRIPTION

PAGI::Simple::Request wraps the PAGI $scope hashref to provide
convenient access to request data. Headers are exposed via
Hash::MultiValue for proper handling of multi-value headers.

=head1 METHODS

=head2 body_stream

    my $stream = $req->body_stream(%opts);

Opt-in streaming interface for request bodies. Options:

=over 4

=item * C<max_bytes> - croak if the total bytes read exceeds this value (defaults to C<Content-Length> when present).

=item * C<decode> - decode chunks (e.g., C<'UTF-8'>); otherwise returns raw bytes.

=item * C<strict> - when decoding, croak on invalid or truncated data (default: replacement).

=item * C<loop> - optional IO::Async::Loop to use for file piping helpers.

=back

Returns a L<PAGI::Simple::BodyStream> object. Streaming is mutually exclusive
with buffered helpers (body/body_params/json_body/uploads/etc); calling buffered
helpers after streaming has begun will croak.

=cut

=head2 new

    my $req = PAGI::Simple::Request->new($scope, $receive);

Create a new Request object wrapping the given PAGI scope.

=cut

sub new ($class, $scope, $receive = undef, $path_params = undef) {
    my $self = bless {
        scope        => $scope,
        receive      => $receive,
        _headers     => undef,  # Lazy-built Hash::MultiValue
        _query       => undef,  # Lazy-built Hash::MultiValue for query params
        _body        => undef,  # Cached raw body
        _body_read   => 0,      # Whether body has been drained
        _body_params => undef,  # Lazy-built Hash::MultiValue for form params
        _path_params => $path_params // {},
        _cookies     => undef,  # Lazy-parsed cookie hashref
        _multipart   => undef,  # Parsed multipart data { fields, uploads }
        _multipart_parsed => 0, # Whether multipart has been parsed
    }, $class;

    return $self;
}

=head2 scope

    my $scope = $req->scope;

Returns the raw PAGI scope hashref.

=cut

sub scope ($self) {
    return $self->{scope};
}

sub _assert_body_not_read ($self) {
    croak "Body already consumed; streaming not available" if $self->{_body_read};
    croak "Body already consumed; streaming not available" if $self->{_body};
    croak "Body already consumed; streaming not available" if $self->{_body_params};
    croak "Body streaming already started" if $self->{_body_stream_created};
}

sub _assert_stream_not_started ($self) {
    croak "Body streaming already started; buffered helpers are unavailable" if $self->{_body_stream_created};
}

=head2 body_stream

    my $stream = $req->body_stream(%opts);

Create a streaming reader for the request body. This is mutually exclusive
with buffered helpers (body, body_params, json_body, etc). Options:

=over 4

=item * C<max_bytes> - croak if total bytes exceed this value (defaults to Content-Length if present).

=item * C<decode> - decode chunks, e.g. C<'UTF-8'> (default: raw bytes).

=item * C<strict> - when decoding, croak on invalid/truncated data (default: replacement).

=item * C<loop> - optional loop for file piping helpers.

=back

The returned stream exposes C<next_chunk>, C<stream_to_file>, and C<stream_to>
for backpressure-friendly consumption, plus helpers like C<bytes_read> and
C<last_raw_chunk> for diagnostics.

=cut

sub body_stream ($self, %opts) {
    $self->_assert_body_not_read;
    $self->{_body_stream_created} = 1;
    my $max_bytes = $opts{max_bytes};
    my $limit_name = defined $max_bytes ? 'max_bytes' : undef;
    if (!defined $max_bytes) {
        my $cl = $self->content_length;
        if (defined $cl) {
            $max_bytes  = $cl;
            $limit_name = 'content-length';
        }
    }
    return PAGI::Simple::BodyStream->new(
        receive   => $self->{receive},
        max_bytes => $max_bytes,
        limit_name => $limit_name,
        loop      => $opts{loop} // ($self->{scope}{pagi}{loop} // undef),
        decode    => $opts{decode},
        strict    => $opts{strict},
    );
}

=head2 method

    my $method = $req->method;  # GET, POST, PUT, DELETE, etc.

Returns the HTTP request method.

=cut

sub method ($self) {
    return $self->{scope}{method} // '';
}

=head2 path

    my $path = $req->path;  # /users/123

Returns the request path (without query string).

=cut

sub path ($self) {
    return $self->{scope}{path} // '/';
}

=head2 query_string

    my $qs = $req->query_string;  # foo=bar&baz=qux

Returns the raw query string (without the leading ?).

=cut

sub query_string ($self) {
    return $self->{scope}{query_string} // '';
}

=head2 raw_query_string

    my $qs = $req->raw_query_string;

Alias for L</query_string>; provided for clarity alongside the raw query
accessors.

=cut

sub raw_query_string ($self) {
    return $self->query_string;
}

=head2 query

    my $query = $req->query;  # Hash::MultiValue
    my @values = $query->get_all('tags');

Returns query parameters as a Hash::MultiValue object. Keys and values are
URL-decoded and then decoded as UTF-8 using replacement characters (U+FFFD)
for invalid byte sequences.

Options:

=over 4

=item * C<strict =E<gt> 1> - croak if the data is not valid UTF-8.

=item * C<raw =E<gt> 1> - skip UTF-8 decoding and return byte strings.

=back

=cut

sub query ($self, %opts) {
    my $strict = delete $opts{strict} // 0;
    my $raw    = delete $opts{raw}    // 0;
    croak("Unknown options to query: " . join(', ', keys %opts)) if %opts;

    my $cache_key = $raw ? '_query_raw' : ($strict ? '_query_strict' : '_query');
    return $self->{$cache_key} if $self->{$cache_key};

    my $parsed = $self->_parse_query_string(
        $self->query_string,
        raw    => $raw,
        strict => $strict,
    );

    $self->{$cache_key} = $parsed;
    return $parsed;
}

=head2 query_param

    my $value = $req->query_param('name');

Returns a single query parameter value (first value if multiple exist).
Returns undef if the parameter is not present.
Accepts the same options as L</query>.

=cut

sub query_param ($self, $name, %opts) {
    my $strict = delete $opts{strict} // 0;
    my $raw    = delete $opts{raw}    // 0;
    croak("Unknown options to query_param: " . join(', ', keys %opts)) if %opts;

    # Hash::MultiValue's get() returns last value, but we want first
    my @values = $self->query(raw => $raw, strict => $strict)->get_all($name);
    return @values ? $values[0] : undef;
}

=head2 query_params

    my $values = $req->query_params('tags');  # Returns arrayref

Returns all values for a query parameter as an arrayref.
Returns an empty arrayref if the parameter is not present.
Accepts the same options as L</query>.

=cut

sub query_params ($self, $name, %opts) {
    my $strict = delete $opts{strict} // 0;
    my $raw    = delete $opts{raw}    // 0;
    croak("Unknown options to query_params: " . join(', ', keys %opts)) if %opts;

    my @values = $self->query(raw => $raw, strict => $strict)->get_all($name);
    return \@values;
}

=head2 raw_query

    my $raw = $req->raw_query;  # Hash::MultiValue with byte strings

Returns query parameters without UTF-8 decoding (percent-decoded bytes).

=cut

sub raw_query ($self) {
    return $self->query(raw => 1);
}

=head2 raw_query_param

    my $raw = $req->raw_query_param('name');

Returns a single query parameter value without UTF-8 decoding.

=cut

sub raw_query_param ($self, $name) {
    return $self->query_param($name, raw => 1);
}

=head2 raw_query_params

    my $values = $req->raw_query_params('tags');

Returns all values for a query parameter without UTF-8 decoding.

=cut

sub raw_query_params ($self, $name) {
    return $self->query_params($name, raw => 1);
}

# Internal: Parse query string into Hash::MultiValue
sub _parse_query_string ($self, $qs, %opts) {
    my $raw    = delete $opts{raw}    // 0;
    my $strict = delete $opts{strict} // 0;
    croak("Unknown options to _parse_query_string: " . join(', ', keys %opts)) if %opts;

    my @pairs;

    return Hash::MultiValue->new() unless defined $qs && length $qs;

    for my $pair (split /[&;]/, $qs) {
        my ($key, $value) = split /=/, $pair, 2;
        next unless defined $key && length $key;

        my $key_raw   = _url_decode($key);
        my $value_raw = defined $value ? _url_decode($value) : '';

        my $key_final   = $raw ? $key_raw   : _decode_utf8($key_raw,   $strict);
        my $value_final = $raw ? $value_raw : _decode_utf8($value_raw, $strict);

        push @pairs, $key_final, $value_final;
    }

    return Hash::MultiValue->new(@pairs);
}

# Internal: URL decode a string
sub _url_decode ($str) {
    return '' unless defined $str;

    # Replace + with space
    $str =~ s/\+/ /g;

    # Decode %XX sequences
    $str =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;

    return $str;
}

# Internal: Decode UTF-8 with replacement or croak in strict mode
sub _decode_utf8 ($str, $strict) {
    return '' unless defined $str;
    my $flag = $strict ? FB_CROAK : FB_DEFAULT;
    $flag |= LEAVE_SRC;
    return decode('UTF-8', $str, $flag);
}

=head2 headers

    my $headers = $req->headers;  # Hash::MultiValue
    my @values = $headers->get_all('Accept');

Returns all headers as a Hash::MultiValue object. Headers are
lowercased for consistent access.

=cut

sub headers ($self) {
    unless ($self->{_headers}) {
        my @pairs;
        my $raw_headers = $self->{scope}{headers} // [];

        for my $header (@$raw_headers) {
            my ($name, $value) = @$header;
            # Lowercase header names for consistent access
            push @pairs, lc($name), $value;
        }

        $self->{_headers} = Hash::MultiValue->new(@pairs);
    }

    return $self->{_headers};
}

=head2 header

    my $value = $req->header('Content-Type');

Returns a single header value (first value if multiple).
Header names are case-insensitive.

=cut

sub header ($self, $name) {
    return $self->headers->get(lc $name);
}

=head2 header_utf8

    my $value = $req->header_utf8('X-Name');
    my $strict = $req->header_utf8('X-Name', strict => 1);

Returns a header value decoded as UTF-8. Invalid byte sequences are
replaced with U+FFFD by default. Pass C<strict =E<gt> 1> to croak on
invalid UTF-8. Returns undef if the header is not present.

=cut

sub header_utf8 ($self, $name, %opts) {
    my $strict = delete $opts{strict} // 0;
    croak("Unknown options to header_utf8: " . join(', ', keys %opts)) if %opts;

    my $value = $self->header($name);
    return undef unless defined $value;

    return _decode_utf8($value, $strict);
}

=head2 content_type

    my $ct = $req->content_type;  # application/json

Returns the Content-Type header value.

=cut

sub content_type ($self) {
    return $self->header('content-type') // '';
}

=head2 content_length

    my $len = $req->content_length;  # 1234

Returns the Content-Length header value as a number.
Returns undef if not present.

=cut

sub content_length ($self) {
    my $len = $self->header('content-length');
    return defined $len ? 0 + $len : undef;
}

=head2 host

    my $host = $req->host;  # example.com:8080

Returns the Host header value.

=cut

sub host ($self) {
    return $self->header('host') // '';
}

=head2 user_agent

    my $ua = $req->user_agent;

Returns the User-Agent header value.

=cut

sub user_agent ($self) {
    return $self->header('user-agent') // '';
}

=head2 is_htmx

    if ($req->is_htmx) { ... }

Returns true if the request is from htmx (HX-Request header is present).

=cut

sub is_htmx ($self) {
    my $hx = $self->header('hx-request');
    return defined($hx) && $hx eq 'true';
}

=head2 is_boosted

    if ($req->is_boosted) { ... }

Returns true if the request is a boosted htmx request (HX-Boosted header is present).
Boosted requests (from hx-boost links) expect full page responses with layout.

=cut

sub is_boosted ($self) {
    my $hx = $self->header('hx-boosted');
    return defined($hx) && $hx eq 'true';
}

=head2 htmx_target

    my $target = $req->htmx_target;  # e.g., "#todo-list"

Returns the HX-Target header value (the CSS selector of the target element).
Returns undef if the header is not present.

=cut

sub htmx_target ($self) {
    return $self->header('hx-target');
}

=head2 htmx_trigger_name

    my $name = $req->htmx_trigger_name;

Returns the HX-Trigger-Name header value (the name attribute of the element
that triggered the request). Returns undef if not present.

=cut

sub htmx_trigger_name ($self) {
    return $self->header('hx-trigger-name');
}

=head2 htmx_trigger

    my $trigger = $req->htmx_trigger;

Returns the HX-Trigger header value (the id of the element that triggered
the request). Returns undef if not present.

=cut

sub htmx_trigger ($self) {
    return $self->header('hx-trigger');
}

=head2 htmx_current_url

    my $url = $req->htmx_current_url;

Returns the HX-Current-URL header value (the URL of the page that initiated
the request). Returns undef if not present.

=cut

sub htmx_current_url ($self) {
    return $self->header('hx-current-url');
}

=head2 htmx_prompt

    my $input = $req->htmx_prompt;

Returns the HX-Prompt header value (user input from hx-prompt attribute).
Returns undef if not present.

=cut

sub htmx_prompt ($self) {
    return $self->header('hx-prompt');
}

=head2 htmx_boosted

    if ($req->htmx_boosted) { ... }

Returns true if the request is from a hx-boost enhanced link or form.

=cut

sub htmx_boosted ($self) {
    my $boosted = $self->header('hx-boosted');
    return defined($boosted) && $boosted eq 'true';
}

=head2 htmx_history_restore_request

    if ($req->htmx_history_restore_request) { ... }

Returns true if the request is a history restoration request after a miss
in the local history cache.

=cut

sub htmx_history_restore_request ($self) {
    my $restore = $self->header('hx-history-restore-request');
    return defined($restore) && $restore eq 'true';
}

=head2 cookies

    my $cookies = $req->cookies;  # { session => 'abc', theme => 'dark' }

Returns a hashref of all cookies from the Cookie header.
Cookie names and values are trimmed and unquoted.

=cut

sub cookies ($self) {
    unless ($self->{_cookies}) {
        my $header = $self->header('cookie') // '';
        $self->{_cookies} = PAGI::Simple::CookieUtil::parse_cookie_header($header);
    }
    return $self->{_cookies};
}

=head2 cookie

    my $value = $req->cookie('session_id');

Returns a single cookie value by name.
Returns undef if the cookie is not present.

=cut

sub cookie ($self, $name) {
    return $self->cookies->{$name};
}

=head2 accepts

    my @types = $req->accepts;  # Parsed Accept header
    # Returns: (['text/html', 1], ['application/json', 0.9], ...)

Returns the parsed Accept header as a list of arrayrefs containing
[media_type, quality] sorted by preference (highest quality first).

If no Accept header is present, returns a single entry for C<*/*>.

=cut

sub accepts ($self) {
    my $accept = $self->header('accept');
    return PAGI::Simple::Negotiate->parse_accept($accept);
}

=head2 accepts_type

    if ($req->accepts_type('application/json')) { ... }
    if ($req->accepts_type('json')) { ... }  # Shortcut

Check if a specific content type is acceptable. Returns true if the
type is acceptable based on the Accept header.

Supports type shortcuts: html, json, xml, text, etc.

=cut

sub accepts_type ($self, $type) {
    my $accept = $self->header('accept');
    return PAGI::Simple::Negotiate->accepts_type($accept, $type);
}

=head2 preferred_type

    my $best = $req->preferred_type('text/html', 'application/json');
    my $best = $req->preferred_type('html', 'json');  # Shortcuts

Given a list of supported content types, returns the one that best matches
the client's Accept header preferences. Returns undef if none are acceptable.

Supports type shortcuts: html, json, xml, text, etc.

=cut

sub preferred_type ($self, @types) {
    my $accept = $self->header('accept');
    return PAGI::Simple::Negotiate->best_match(\@types, $accept);
}

=head2 is_secure

    if ($req->is_secure) { ... }

Returns true if the request was made over HTTPS.

=cut

sub is_secure ($self) {
    return ($self->{scope}{scheme} // 'http') eq 'https';
}

=head2 scheme

    my $scheme = $req->scheme;  # http or https

Returns the request scheme.

=cut

sub scheme ($self) {
    return $self->{scope}{scheme} // 'http';
}

=head2 server_name

    my $name = $req->server_name;

Returns the server name from scope.

=cut

sub server_name ($self) {
    return $self->{scope}{server}[0] // '';
}

=head2 server_port

    my $port = $req->server_port;

Returns the server port from scope.

=cut

sub server_port ($self) {
    return $self->{scope}{server}[1] // 80;
}

=head2 client_ip

    my $ip = $req->client_ip;

Returns the client IP address from scope.

=cut

sub client_ip ($self) {
    return $self->{scope}{client}[0] // '';
}

=head2 client_port

    my $port = $req->client_port;

Returns the client port from scope.

=cut

sub client_port ($self) {
    return $self->{scope}{client}[1] // 0;
}

=head2 path_param

    my $id = $req->path_param('id');

Returns a path parameter captured from the route pattern.
Returns undef if the parameter doesn't exist.

=cut

sub path_param ($self, $name) {
    return $self->{_path_params}{$name};
}

=head2 path_params

    my $params = $req->path_params;

Returns a hashref of all captured path parameters.

=cut

sub path_params ($self) {
    return $self->{_path_params};
}

=head1 REQUEST BODY METHODS

=head2 body

    my $body = await $req->body;

Drains and returns the raw request body as a string. The body is cached
after the first call, so subsequent calls return the cached value.

This is an async method that returns a Future.

=cut

async sub body ($self) {
    $self->_assert_stream_not_started;
    # Return cached body if already read
    return $self->{_body} if $self->{_body_read};

    my $body = '';
    my $receive = $self->{receive};

    # If no receive function, return empty body
    unless ($receive) {
        $self->{_body_read} = 1;
        $self->{_body} = '';
        return '';
    }

    # Drain body chunks
    while (1) {
        my $event = await $receive->();
        my $type = $event->{type} // '';

        if ($type eq 'http.request') {
            $body .= $event->{body} // '';
            last unless $event->{more};
        }
        elsif ($type eq 'http.disconnect') {
            last;
        }
        else {
            # Unknown event type, stop reading
            last;
        }
    }

    $self->{_body_read} = 1;
    $self->{_body} = $body;

    return $body;
}

=head2 body_params

    my $params = await $req->body_params;  # Hash::MultiValue

Parses the request body as form data (application/x-www-form-urlencoded)
and returns a Hash::MultiValue object. Values are URL-decoded and then
decoded as UTF-8 with replacement characters (U+FFFD) for invalid byte
sequences.

Options:

=over 4

=item * C<strict =E<gt> 1> - croak on invalid UTF-8.

=item * C<raw =E<gt> 1> - skip UTF-8 decoding and return byte strings.

=back

=cut

async sub body_params ($self, %opts) {
    my $strict = delete $opts{strict} // 0;
    my $raw    = delete $opts{raw}    // 0;
    croak("Unknown options to body_params: " . join(', ', keys %opts)) if %opts;

    my $cache_key = $raw ? '_body_params_raw' : ($strict ? '_body_params_strict' : '_body_params');
    return $self->{$cache_key} if $self->{$cache_key};

    my $body = await $self->body;
    my $ct = $self->content_type;

    # Only parse form data
    if ($ct =~ m{^application/x-www-form-urlencoded}i) {
        $self->{$cache_key} = $self->_parse_query_string(
            $body,
            raw    => $raw,
            strict => $strict,
        );
    }
    else {
        $self->{$cache_key} = Hash::MultiValue->new();
    }

    return $self->{$cache_key};
}

=head2 body_param

    my $value = await $req->body_param('email');

Returns a single form parameter value (first value if multiple exist).
Returns undef if the parameter is not present.
Accepts the same options as L</body_params>.

=cut

async sub body_param ($self, $name, %opts) {
    my $params = await $self->body_params(%opts);
    my @values = $params->get_all($name);
    return @values ? $values[0] : undef;
}

=head2 raw_body_params

    my $params = await $req->raw_body_params;

Returns form parameters without UTF-8 decoding (percent-decoded bytes).

=cut

async sub raw_body_params ($self) {
    return await $self->body_params(raw => 1);
}

=head2 raw_body_param

    my $value = await $req->raw_body_param('email');

Returns a single form parameter value without UTF-8 decoding.

=cut

async sub raw_body_param ($self, $name) {
    return await $self->body_param($name, raw => 1);
}

=head2 json_body

    my $data = await $req->json_body;

Parses the request body as JSON and returns the decoded data structure.
Dies if the body is not valid JSON.

=cut

async sub json_body ($self) {
    my $body = await $self->body;
    return $json->decode($body);
}

=head2 json_body_safe

    my $data = await $req->json_body_safe;

Parses the request body as JSON and returns the decoded data structure.
Returns undef if the body is not valid JSON (does not die).

=cut

async sub json_body_safe ($self) {
    my $body = await $self->body;
    my $data = eval { $json->decode($body) };
    return $data;
}

=head1 FILE UPLOAD METHODS

=head2 upload

    my $file = await $req->upload('avatar');

    if ($file) {
        my $filename = $file->filename;
        my $content  = $file->slurp;
        $file->move_to('/uploads/' . $file->basename);
    }

Returns a single L<PAGI::Simple::Upload> object for the given field name.
If multiple files were uploaded with the same name, returns the first one.
Returns undef if no file was uploaded for that field.

=cut

async sub upload ($self, $name) {
    await $self->_parse_multipart;
    my $uploads = $self->{_multipart}{uploads}{$name};
    return $uploads && @$uploads ? $uploads->[0] : undef;
}

=head2 uploads

    my $files = await $req->uploads('photos');

    for my $file (@$files) {
        $file->move_to("/uploads/" . $file->basename);
    }

Returns an arrayref of L<PAGI::Simple::Upload> objects for the given field name.
Returns an empty arrayref if no files were uploaded for that field.

=cut

async sub uploads ($self, $name) {
    await $self->_parse_multipart;
    return $self->{_multipart}{uploads}{$name} // [];
}

=head2 uploads_all

    my $all = await $req->uploads_all;

    for my $name (keys %$all) {
        for my $file (@{$all->{$name}}) {
            print "Field: $name, File: " . $file->filename . "\n";
        }
    }

Returns a hashref of all uploaded files. Keys are field names, values are
arrayrefs of L<PAGI::Simple::Upload> objects.

=cut

async sub uploads_all ($self) {
    await $self->_parse_multipart;
    return $self->{_multipart}{uploads} // {};
}

=head2 has_uploads

    if (await $req->has_uploads) { ... }

Returns true if the request contains any file uploads.

=cut

async sub has_uploads ($self) {
    await $self->_parse_multipart;
    my $uploads = $self->{_multipart}{uploads};
    return $uploads && keys %$uploads ? 1 : 0;
}

=head2 is_multipart

    if ($req->is_multipart) { ... }

Returns true if the request has a multipart/form-data content type.
This is a synchronous method that just checks the Content-Type header.

=cut

sub is_multipart ($self) {
    my $ct = $self->content_type;
    return $ct =~ m{^multipart/form-data}i ? 1 : 0;
}

# Internal: Parse multipart body (lazy, cached)
async sub _parse_multipart ($self) {
    return if $self->{_multipart_parsed};
    $self->{_multipart_parsed} = 1;

    # Initialize with empty data
    $self->{_multipart} = { fields => {}, uploads => {} };

    # Check if this is multipart
    my $ct = $self->content_type;
    return unless $ct =~ m{^multipart/form-data}i;

    # Get the body
    my $body = await $self->body;
    return unless length $body;

    # Parse multipart
    my $parser = PAGI::Simple::MultipartParser->new;
    eval {
        $self->{_multipart} = $parser->parse($ct, $body);
    };
    if ($@) {
        warn "Multipart parse error: $@";
        $self->{_multipart} = { fields => {}, uploads => {} };
    }
}

=head1 SEE ALSO

L<PAGI::Simple>, L<PAGI::Simple::Context>, L<PAGI::Simple::Upload>, L<Hash::MultiValue>

=head1 AUTHOR

PAGI Contributors

=cut

1;
