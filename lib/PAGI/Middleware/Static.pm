package PAGI::Middleware::Static;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;
use File::Spec;
use Digest::MD5 'md5_hex';
use Fcntl ':mode';
use IO::Async::Loop;
use PAGI::Util::AsyncFile;

=head1 NAME

PAGI::Middleware::Static - Static file serving middleware

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'Static',
            root        => '/var/www/static',
            path        => qr{^/static/},
            pass_through => 1;
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::Static serves static files from a specified directory.
It includes path traversal protection, MIME type detection, ETag support
for caching, and Range request support for partial content.

=head1 CONFIGURATION

=over 4

=item * root (required)

The root directory to serve files from.

=item * path (default: qr{^/})

A regex or coderef to match request paths. Only matching paths are handled.

=item * pass_through (default: 0)

If true, pass requests to inner app when file not found instead of returning 404.

=item * index (default: ['index.html', 'index.htm'])

Array of index file names to try for directory requests.

=item * encoding (default: undef)

If set, look for pre-compressed files with this extension (e.g., 'gz' for .gz files).

=back

=cut

# MIME type mapping
my %MIME_TYPES = (
    html  => 'text/html',
    htm   => 'text/html',
    css   => 'text/css',
    js    => 'application/javascript',
    json  => 'application/json',
    xml   => 'application/xml',
    txt   => 'text/plain',
    csv   => 'text/csv',

    # Images
    png   => 'image/png',
    jpg   => 'image/jpeg',
    jpeg  => 'image/jpeg',
    gif   => 'image/gif',
    svg   => 'image/svg+xml',
    ico   => 'image/x-icon',
    webp  => 'image/webp',

    # Fonts
    woff  => 'font/woff',
    woff2 => 'font/woff2',
    ttf   => 'font/ttf',
    otf   => 'font/otf',
    eot   => 'application/vnd.ms-fontobject',

    # Documents
    pdf   => 'application/pdf',
    zip   => 'application/zip',
    gz    => 'application/gzip',
    tar   => 'application/x-tar',

    # Media
    mp3   => 'audio/mpeg',
    mp4   => 'video/mp4',
    webm  => 'video/webm',
    ogg   => 'audio/ogg',
    wav   => 'audio/wav',

    # Default
    bin   => 'application/octet-stream',
);

sub _init {
    my ($self, $config) = @_;

    $self->{root}         = $config->{root} // die "Static middleware requires 'root' option";
    $self->{path}         = $config->{path} // qr{^/};
    $self->{pass_through} = $config->{pass_through} // 0;
    $self->{index}        = $config->{index} // ['index.html', 'index.htm'];
    $self->{encoding}     = $config->{encoding};

    # Normalize root path
    $self->{root} = File::Spec->rel2abs($self->{root});
}

sub wrap {
    my ($self, $app) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        # Only handle HTTP GET/HEAD requests
        if ($scope->{type} ne 'http' || ($scope->{method} ne 'GET' && $scope->{method} ne 'HEAD')) {
            await $app->($scope, $receive, $send);
            return;
        }

        my $path = $scope->{path};

        # Check if path matches our pattern
        my $path_match = $self->{path};
        if (ref($path_match) eq 'Regexp') {
            unless ($path =~ $path_match) {
                await $app->($scope, $receive, $send);
                return;
            }
        } elsif (ref($path_match) eq 'CODE') {
            unless ($path_match->($path)) {
                await $app->($scope, $receive, $send);
                return;
            }
        }

        # Build file path
        my $file_path = $self->_resolve_path($path);

        # Check for path traversal
        unless ($file_path && $self->_is_safe_path($file_path)) {
            await $self->_send_error($send, 403, 'Forbidden');
            return;
        }

        # Check if file exists
        unless (-e $file_path) {
            if ($self->{pass_through}) {
                await $app->($scope, $receive, $send);
                return;
            }
            await $self->_send_error($send, 404, 'Not Found');
            return;
        }

        # Handle directory with index files
        if (-d $file_path) {
            my $index_file = $self->_find_index($file_path);
            if ($index_file) {
                $file_path = $index_file;
            } else {
                if ($self->{pass_through}) {
                    await $app->($scope, $receive, $send);
                    return;
                }
                await $self->_send_error($send, 404, 'Not Found');
                return;
            }
        }

        # Get file stats
        my @stat = stat($file_path);
        unless (@stat) {
            await $self->_send_error($send, 500, 'Cannot stat file');
            return;
        }

        my $size  = $stat[7];
        my $mtime = $stat[9];

        # Generate ETag
        my $etag = $self->_generate_etag($file_path, $size, $mtime);

        # Check If-None-Match for 304 response
        my $if_none_match = $self->_get_header($scope, 'if-none-match');
        if ($if_none_match && $if_none_match eq $etag) {
            await $send->({
                type    => 'http.response.start',
                status  => 304,
                headers => [
                    ['etag', $etag],
                ],
            });
            await $send->({
                type => 'http.response.body',
                body => '',
                more => 0,
            });
            return;
        }

        # Get MIME type
        my $content_type = $self->_get_mime_type($file_path);

        # Check for Range request
        my $range_header = $self->_get_header($scope, 'range');
        my ($start, $end, $is_range) = $self->_parse_range($range_header, $size);

        if ($is_range && !defined $start) {
            # Invalid range
            await $self->_send_error($send, 416, 'Range Not Satisfiable');
            return;
        }

        # Build headers
        my @headers = (
            ['content-type', $content_type],
            ['etag', $etag],
            ['last-modified', $self->_format_http_date($mtime)],
            ['accept-ranges', 'bytes'],
        );

        my $status;
        my $body_size;

        if ($is_range) {
            $status = 206;
            $body_size = $end - $start + 1;
            push @headers, ['content-range', "bytes $start-$end/$size"];
            push @headers, ['content-length', $body_size];
        } else {
            $status = 200;
            $body_size = $size;
            push @headers, ['content-length', $size];
        }

        # Send response start
        await $send->({
            type    => 'http.response.start',
            status  => $status,
            headers => \@headers,
        });

        # For HEAD requests, don't send body
        if ($scope->{method} eq 'HEAD') {
            await $send->({
                type => 'http.response.body',
                body => '',
                more => 0,
            });
            return;
        }

        # Read and send file content using async I/O via IO::Async::Loop singleton
        my $chunk_size = 64 * 1024;  # 64KB chunks
        my $loop = IO::Async::Loop->new;

        if (!$is_range) {
            # Use non-blocking async file I/O for full file reads (chunked)
            my $bytes_sent = 0;
            eval {
                await PAGI::Util::AsyncFile->read_file_chunked(
                    $loop, $file_path,
                    async sub  {
        my ($chunk) = @_;
                        $bytes_sent += length($chunk);
                        my $more = $bytes_sent < $body_size ? 1 : 0;
                        await $send->({
                            type => 'http.response.body',
                            body => $chunk,
                            more => $more,
                        });
                    },
                    chunk_size => $chunk_size
                );
            };
            if ($@) {
                await $self->_send_error($send, 500, 'Cannot read file');
                return;
            }
        }
        else {
            # For range requests, read full file async and slice
            eval {
                my $full_content = await PAGI::Util::AsyncFile->read_file($loop, $file_path);
                my $content = substr($full_content, $start, $body_size);
                await $send->({
                    type => 'http.response.body',
                    body => $content,
                    more => 0,
                });
            };
            if ($@) {
                await $self->_send_error($send, 500, 'Cannot read file');
                return;
            }
        }
    };
}

sub _resolve_path {
    my ($self, $url_path) = @_;

    # Decode URL path
    my $decoded = $url_path;
    $decoded =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;

    # Remove query string
    $decoded =~ s/\?.*//;

    # Combine with root (use manual concat to preserve .. for security check)
    my $root = $self->{root};
    $root =~ s{/$}{};  # Remove trailing slash from root
    return $root . $decoded;
}

sub _is_safe_path {
    my ($self, $file_path) = @_;

    my $root = $self->{root};

    # Manually resolve the path to handle .. without requiring file to exist
    my $abs_path = $self->_resolve_dots($file_path);
    return 0 unless defined $abs_path;

    # Normalize both paths
    $abs_path =~ s{/+}{/}g;
    $root =~ s{/+}{/}g;
    $root =~ s{/$}{};
    $abs_path =~ s{/$}{};

    # Path must start with root
    return $abs_path =~ m{^\Q$root\E(?:/|$)};
}

sub _resolve_dots {
    my ($self, $path) = @_;

    # Split path into components
    my @parts = split m{/}, $path;
    my @resolved;

    for my $part (@parts) {
        if ($part eq '' || $part eq '.') {
            # Skip empty and current dir
            next;
        } elsif ($part eq '..') {
            # Go up one directory
            if (@resolved) {
                pop @resolved;
            }
            # If we can't go up, the path is invalid (would escape root)
        } else {
            push @resolved, $part;
        }
    }

    # Reconstruct absolute path
    return '/' . join('/', @resolved);
}

sub _find_index {
    my ($self, $dir_path) = @_;

    for my $index (@{$self->{index}}) {
        my $index_path = File::Spec->catfile($dir_path, $index);
        return $index_path if -f $index_path;
    }
    return;
}

sub _generate_etag {
    my ($self, $file_path, $size, $mtime) = @_;

    my $data = "$file_path:$size:$mtime";
    return '"' . md5_hex($data) . '"';
}

sub _get_mime_type {
    my ($self, $file_path) = @_;

    my ($ext) = $file_path =~ /\.([^.]+)$/;
    $ext = lc($ext // '');
    return $MIME_TYPES{$ext} // 'application/octet-stream';
}

sub _get_header {
    my ($self, $scope, $name) = @_;

    $name = lc($name);
    for my $h (@{$scope->{headers} // []}) {
        return $h->[1] if lc($h->[0]) eq $name;
    }
    return;
}

sub _parse_range {
    my ($self, $range_header, $size) = @_;

    return (undef, undef, 0) unless $range_header;

    # Parse "bytes=start-end" format
    if ($range_header =~ /^bytes=(\d*)-(\d*)$/) {
        my ($start, $end) = ($1, $2);

        if ($start eq '' && $end ne '') {
            # Suffix range: last N bytes
            $start = $size - $end;
            $end = $size - 1;
        } elsif ($start ne '' && $end eq '') {
            # From start to end
            $start = int($start);
            $end = $size - 1;
        } else {
            $start = int($start);
            $end = int($end);
        }

        # Validate range
        return (undef, undef, 1) if $start > $end || $start >= $size;

        $end = $size - 1 if $end >= $size;

        return ($start, $end, 1);
    }

    return (undef, undef, 0);
}

sub _format_http_date {
    my ($self, $epoch) = @_;

    my @days = qw(Sun Mon Tue Wed Thu Fri Sat);
    my @months = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
    my @t = gmtime($epoch);
    return sprintf("%s, %02d %s %04d %02d:%02d:%02d GMT",
        $days[$t[6]], $t[3], $months[$t[4]], $t[5] + 1900,
        $t[2], $t[1], $t[0]);
}

async sub _send_error {
    my ($self, $send, $status, $message) = @_;

    await $send->({
        type    => 'http.response.start',
        status  => $status,
        headers => [
            ['content-type', 'text/plain'],
            ['content-length', length($message)],
        ],
    });
    await $send->({
        type => 'http.response.body',
        body => $message,
        more => 0,
    });
}

1;

__END__

=head1 SECURITY

This middleware includes path traversal protection to prevent access to
files outside the configured root directory. Requests containing ".."
sequences that would escape the root are rejected with 403 Forbidden.

=head1 CACHING

The middleware generates ETags based on file path, size, and modification
time. Clients can use If-None-Match to receive 304 Not Modified responses
when the file hasn't changed.

=head1 RANGE REQUESTS

The middleware supports HTTP Range requests for partial content, useful
for resumable downloads and media streaming. Only single byte ranges
are supported (not multi-range requests).

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

=cut
