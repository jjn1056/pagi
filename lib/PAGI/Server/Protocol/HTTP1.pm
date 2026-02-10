package PAGI::Server::Protocol::HTTP1;
use strict;
use warnings;
use HTTP::Parser::XS qw(parse_http_request);
use URI::Escape qw(uri_unescape);
use Encode qw(decode);
use PAGI::Server ();


# =============================================================================
# Header Validation (CRLF Injection Prevention)
# =============================================================================
# RFC 7230 Section 3.2.6: Field values MUST NOT contain CR or LF
# Additionally, null bytes are rejected as they can cause truncation attacks

sub _validate_header_name {
    my ($name) = @_;

    if ($name =~ /[\r\n\0]/) {
        die "Invalid header name: contains CR, LF, or null byte\n";
    }
    # RFC 7230: token = 1*tchar
    # For simplicity, we just reject control characters and delimiters
    if ($name =~ /[[:cntrl:]]/) {
        die "Invalid header name: contains control characters\n";
    }
    return $name;
}

sub _validate_header_value {
    my ($value) = @_;

    if ($value =~ /[\r\n\0]/) {
        die "Invalid header value: contains CR, LF, or null byte\n";
    }
    return $value;
}

=head1 NAME

PAGI::Server::Protocol::HTTP1 - HTTP/1.1 protocol handler

=head1 SYNOPSIS

    use PAGI::Server::Protocol::HTTP1;

    my $proto = PAGI::Server::Protocol::HTTP1->new;

    # Parse incoming request
    my ($request, $consumed) = $proto->parse_request($buffer);

    # Serialize response
    my $bytes = $proto->serialize_response_start(200, \@headers, $chunked);
    $bytes   .= $proto->serialize_response_body($chunk, $more);

=head1 DESCRIPTION

PAGI::Server::Protocol::HTTP1 isolates HTTP/1.1 wire-format parsing and
serialization from PAGI event handling. This allows clean separation of
protocol handling and future addition of HTTP/2 or HTTP/3 modules with
the same interface.

=head1 METHODS

=head2 new

    my $proto = PAGI::Server::Protocol::HTTP1->new;

Creates a new HTTP1 protocol handler.

=head2 parse_request

    my ($request_info, $bytes_consumed) = $proto->parse_request($buffer);

Parses an HTTP request from the buffer. Returns undef if the request
is incomplete. On success, returns:

    $request_info = {
        method       => 'GET',
        path         => '/foo',
        raw_path     => '/foo%20bar',
        query_string => 'a=1',
        http_version => '1.1',
        headers      => [ ['host', 'localhost'], ... ],
        content_length => 0,  # or undef if not present
        chunked      => 0,    # 1 if Transfer-Encoding: chunked
    };

=head2 serialize_response_start

    my $bytes = $proto->serialize_response_start($status, \@headers, $chunked);

Serializes the response line and headers.

=head2 serialize_response_body

    my $bytes = $proto->serialize_response_body($chunk, $more, $chunked);

Serializes a body chunk. Uses chunked encoding if $chunked is true.

=head2 serialize_trailers

    my $bytes = $proto->serialize_trailers(\@headers);

Serializes HTTP trailers.

=cut

# Cached Date header (regenerated at most once per second)
my $_cached_date;
my $_cached_date_time = 0;

# Cached default Server header (lazy-init to ensure VERSION is loaded)
my $_server_header;

# HTTP status code reason phrases
my %STATUS_PHRASES = (
    100 => 'Continue',
    101 => 'Switching Protocols',
    200 => 'OK',
    201 => 'Created',
    204 => 'No Content',
    301 => 'Moved Permanently',
    302 => 'Found',
    304 => 'Not Modified',
    400 => 'Bad Request',
    401 => 'Unauthorized',
    403 => 'Forbidden',
    404 => 'Not Found',
    405 => 'Method Not Allowed',
    413 => 'Payload Too Large',
    414 => 'URI Too Long',
    431 => 'Request Header Fields Too Large',
    500 => 'Internal Server Error',
    502 => 'Bad Gateway',
    503 => 'Service Unavailable',
);

sub new {
    my ($class, %args) = @_;

    my $self = bless {
        max_header_size       => $args{max_header_size} // 8192,
        max_request_line_size => $args{max_request_line_size} // 8192,  # 8KB per RFC 7230
        max_header_count      => $args{max_header_count} // 100,  # Max number of headers
    }, $class;
    return $self;
}

sub parse_request {
    my ($self, $buffer_ref) = @_;

    # HTTP::Parser::XS expects a scalar, not a reference
    my $buffer = ref $buffer_ref ? $$buffer_ref : $buffer_ref;

    # Check for complete headers (look for \r\n\r\n)
    my $header_end = index($buffer, "\r\n\r\n");
    return (undef, 0) if $header_end < 0;

    # Check request line length (first line before \r\n)
    my $first_line_end = index($buffer, "\r\n");
    if ($first_line_end > $self->{max_request_line_size}) {
        return ({ error => 414, message => 'URI Too Long' }, $header_end + 4);
    }

    # Check max header size
    if ($header_end > $self->{max_header_size}) {
        return ({ error => 431, message => 'Request Header Fields Too Large' }, $header_end + 4);
    }

    # Parse using HTTP::Parser::XS
    my %env;
    my $ret = parse_http_request($buffer, \%env);

    # Return error for malformed request (-1)
    if ($ret == -1) {
        # Find end of malformed request line/headers
        my $consumed = $header_end + 4;
        return ({ error => 400, message => 'Bad Request' }, $consumed);
    }

    # Return undef if incomplete (-2)
    return (undef, 0) if $ret < 0;

    # Extract method and path
    my $method = $env{REQUEST_METHOD};
    my $raw_uri = $env{REQUEST_URI} // '/';

    # Split path and query string
    my ($raw_path, $query_string) = split(/\?/, $raw_uri, 2);
    $raw_path //= '/';
    $query_string //= '';

    # Decode path (URL-decode, then UTF-8 decode with fallback)
    # Mojolicious-style: try UTF-8 decode, fall back to original bytes if invalid
    my $unescaped = uri_unescape($raw_path);
    my $path = eval { decode('UTF-8', $unescaped, Encode::FB_CROAK) } // $unescaped;

    # Build headers array with lowercase names
    my @headers;
    my $content_length;
    my $chunked = 0;
    my $expect_continue = 0;
    my @cookie_values;

    for my $key (keys %env) {
        # Optimized: use index() + substr() instead of regex (faster per NYTProf)
        if (index($key, 'HTTP_') == 0) {
            my $header_name = lc(substr($key, 5));
            $header_name =~ tr/_/-/;  # Optimized: tr/// is faster than s///g
            my $value = $env{$key};

            # Handle Cookie header normalization
            if ($header_name eq 'cookie') {
                push @cookie_values, $value;
                next;
            }

            # Check for Transfer-Encoding: chunked
            if ($header_name eq 'transfer-encoding' && $value =~ /chunked/i) {
                $chunked = 1;
            }

            # Check for Expect: 100-continue
            if ($header_name eq 'expect' && lc($value) eq '100-continue') {
                $expect_continue = 1;
            }

            push @headers, [$header_name, $value];
        }
    }

    # Add normalized cookie header if present
    if (@cookie_values) {
        push @headers, ['cookie', join('; ', @cookie_values)];
    }

    # Check header count limit (DoS protection)
    if (@headers > $self->{max_header_count}) {
        return ({ error => 431, message => 'Request Header Fields Too Large' }, $header_end + 4);
    }

    # Add content-type and content-length from env
    if (defined $env{CONTENT_TYPE}) {
        push @headers, ['content-type', $env{CONTENT_TYPE}];
    }
    if (defined $env{CONTENT_LENGTH}) {
        my $cl_value = $env{CONTENT_LENGTH};

        # RFC 7230 Section 3.3.2: Content-Length = 1*DIGIT
        # Must be only digits, no whitespace, no negative sign
        if ($cl_value !~ /^\d+$/) {
            return ({ error => 400, message => 'Bad Request' }, $header_end + 4);
        }

        # Check for unreasonably large values (>2GB indicates potential DoS)
        # Using string length check to avoid Perl's numeric conversion issues
        if (length($cl_value) > 10 || $cl_value > 2_147_483_647) {
            return ({ error => 413, message => 'Payload Too Large' }, $header_end + 4);
        }

        push @headers, ['content-length', $cl_value];
        $content_length = $cl_value + 0;
    }

    # Determine HTTP version (optimized: substr instead of regex)
    my $http_version = '1.1';
    if ($env{SERVER_PROTOCOL} && index($env{SERVER_PROTOCOL}, 'HTTP/') == 0) {
        $http_version = substr($env{SERVER_PROTOCOL}, 5);
    }

    # RFC 7230 Section 5.4: A client MUST send a Host header field in all
    # HTTP/1.1 request messages. A server MUST respond with a 400 (Bad Request)
    # status code to any HTTP/1.1 request message that lacks a Host header field.
    if ($http_version eq '1.1' && !defined $env{HTTP_HOST}) {
        return ({ error => 400, message => 'Bad Request' }, $header_end + 4);
    }

    my $request = {
        method          => $method,
        path            => $path,
        raw_path        => $raw_path,
        query_string    => $query_string,
        http_version    => $http_version,
        headers         => \@headers,
        content_length  => $content_length,
        chunked         => $chunked,
        expect_continue => $expect_continue,
    };

    return ($request, $ret);
}

sub serialize_response_start {
    my ($self, $status, $headers, $chunked, $http_version) = @_;
    $chunked //= 0;
    $http_version //= '1.1';

    my $phrase = $STATUS_PHRASES{$status} // 'Unknown';
    my $response = "HTTP/$http_version $status $phrase\r\n";

    # Serialize headers and detect app-provided Server header in a single pass
    my $has_server = 0;
    for my $header (@$headers) {
        my ($name, $value) = @$header;
        $has_server = 1 if lc($name) eq 'server';
        $name = _validate_header_name($name);
        $value = _validate_header_value($value);
        $response .= "$name: $value\r\n";
    }

    # Add default Server header if app didn't provide one
    unless ($has_server) {
        $_server_header //= "Server: PAGI::Server/$PAGI::Server::VERSION\r\n";
        $response .= $_server_header;
    }

    # Add Transfer-Encoding if chunked (HTTP/1.1 only)
    if ($chunked && $http_version eq '1.1') {
        $response .= "Transfer-Encoding: chunked\r\n";
    }

    $response .= "\r\n";
    return $response;
}

sub serialize_response_body {
    my ($self, $chunk, $more, $chunked) = @_;
    $chunked //= 0;

    return '' unless defined $chunk && length $chunk;

    if ($chunked) {
        my $len = sprintf("%x", length($chunk));
        my $body = "$len\r\n$chunk\r\n";

        # Add final chunk if no more data
        if (!$more) {
            $body .= "0\r\n\r\n";
        }

        return $body;
    } else {
        return $chunk;
    }
}

sub serialize_chunk_end {
    my ($self) = @_;

    return "0\r\n\r\n";
}

sub serialize_continue {
    my ($self) = @_;

    return "HTTP/1.1 100 Continue\r\n\r\n";
}

sub serialize_trailers {
    my ($self, $headers) = @_;

    my $trailers = '';
    for my $header (@$headers) {
        my ($name, $value) = @$header;
        $name = _validate_header_name($name);
        $value = _validate_header_value($value);
        $trailers .= "$name: $value\r\n";
    }
    $trailers .= "\r\n";
    return $trailers;
}

sub format_date {
    my ($self) = @_;

    my $now = time();
    if ($now != $_cached_date_time) {
        $_cached_date_time = $now;
        my @days = qw(Sun Mon Tue Wed Thu Fri Sat);
        my @months = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
        my @gmt = gmtime($now);
        $_cached_date = sprintf("%s, %02d %s %04d %02d:%02d:%02d GMT",
            $days[$gmt[6]], $gmt[3], $months[$gmt[4]], $gmt[5] + 1900,
            $gmt[2], $gmt[1], $gmt[0]);
    }
    return $_cached_date;
}

=head2 parse_chunked_body

    my ($data, $bytes_consumed, $complete) = $proto->parse_chunked_body($buffer);

Parses chunked Transfer-Encoding body from the buffer. Returns:
- $data: decoded body data (may be empty string)
- $bytes_consumed: number of bytes consumed from buffer
- $complete: 1 if final chunk (0-length) was seen, 0 otherwise

Returns (undef, 0, 0) if more data is needed.

=cut

sub parse_chunked_body {
    my ($self, $buffer_ref) = @_;

    my $buffer = ref $buffer_ref ? $$buffer_ref : $buffer_ref;
    my $data = '';
    my $total_consumed = 0;
    my $complete = 0;

    while (1) {
        # Find chunk size line
        my $crlf = index($buffer, "\r\n", $total_consumed);
        last if $crlf < 0;

        # Parse chunk size (hex)
        my $size_line = substr($buffer, $total_consumed, $crlf - $total_consumed);
        $size_line =~ s/;.*//;  # Remove chunk extensions
        $size_line =~ s/^\s+|\s+$//g;  # Trim whitespace

        # Validate chunk size is valid hex (RFC 7230 Section 4.1)
        if ($size_line eq '' || $size_line !~ /^[0-9a-fA-F]+$/) {
            return ({ error => 400, message => 'Invalid chunk size' }, 0, 0);
        }

        my $chunk_size = hex($size_line);

        # Check if we have the full chunk + trailing CRLF
        my $chunk_start = $crlf + 2;
        my $chunk_end = $chunk_start + $chunk_size + 2;  # +2 for trailing CRLF

        if (length($buffer) < $chunk_end) {
            last;  # Need more data
        }

        # Extract chunk data
        if ($chunk_size > 0) {
            $data .= substr($buffer, $chunk_start, $chunk_size);
        }

        $total_consumed = $chunk_end;

        # Check for final chunk
        if ($chunk_size == 0) {
            $complete = 1;
            last;
        }
    }

    return ($data, $total_consumed, $complete);
}

1;

__END__

=head1 SEE ALSO

L<PAGI::Server::Connection>, L<HTTP::Parser::XS>

=head1 AUTHOR

John Napiorkowski E<lt>jjnapiork@cpan.orgE<gt>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
