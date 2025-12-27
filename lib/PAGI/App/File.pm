package PAGI::App::File;

use strict;
use warnings;
use Future::AsyncAwait;
use Digest::MD5 qw(md5_hex);
use File::Spec;
use Cwd ();  # For realpath

=head1 NAME

PAGI::App::File - Serve static files

=head1 SYNOPSIS

    use PAGI::App::File;

    my $app = PAGI::App::File->new(
        root => '/var/www/static',
    )->to_app;

=head1 DESCRIPTION

PAGI::App::File serves static files from a configured root directory.

=head2 Features

=over 4

=item * Efficient streaming (no memory bloat for large files)

=item * ETag caching with If-None-Match support (304 Not Modified)

=item * Range requests (HTTP 206 Partial Content)

=item * Automatic MIME type detection for common file types

=item * Index file resolution (index.html, index.htm)

=back

=head2 Security

This module implements multiple layers of path traversal protection:

=over 4

=item * Null byte injection blocking

=item * Double-dot and triple-dot component blocking

=item * Backslash normalization (Windows path separator)

=item * Hidden file blocking (dotfiles like .htaccess, .env)

=item * Symlink escape detection via realpath verification

=back

=cut

our %MIME_TYPES = (
    html => 'text/html',
    htm  => 'text/html',
    css  => 'text/css',
    js   => 'application/javascript',
    json => 'application/json',
    xml  => 'application/xml',
    txt  => 'text/plain',
    pl   => 'text/plain',
    md   => 'text/plain',
    png  => 'image/png',
    jpg  => 'image/jpeg',
    jpeg => 'image/jpeg',
    gif  => 'image/gif',
    svg  => 'image/svg+xml',
    ico  => 'image/x-icon',
    webp => 'image/webp',
    woff => 'font/woff',
    woff2=> 'font/woff2',
    ttf  => 'font/ttf',
    pdf  => 'application/pdf',
    zip  => 'application/zip',
    mp3  => 'audio/mpeg',
    mp4  => 'video/mp4',
    webm => 'video/webm',
);

sub new {
    my ($class, %args) = @_;

    my $root = $args{root} // '.';
    # Resolve root to absolute path for security comparisons
    my $abs_root = Cwd::realpath($root) // $root;

    my $self = bless {
        root          => $abs_root,
        default_type  => $args{default_type} // 'application/octet-stream',
        index         => $args{index} // ['index.html', 'index.htm'],
        handle_ranges => $args{handle_ranges} // 1,
    }, $class;
    return $self;
}

sub to_app {
    my ($self) = @_;

    my $root = $self->{root};

    return async sub  {
        my ($scope, $receive, $send) = @_;
        die "Unsupported scope type: $scope->{type}" if $scope->{type} ne 'http';

        my $method = uc($scope->{method} // '');
        unless ($method eq 'GET' || $method eq 'HEAD') {
            await $self->_send_error($send, 405, 'Method Not Allowed');
            return;
        }

        my $path = $scope->{path} // '/';

        # Security: Block null byte injection
        if ($path =~ /\0/) {
            await $self->_send_error($send, 400, 'Bad Request');
            return;
        }

        # Security: Normalize backslashes to forward slashes
        $path =~ s{\\}{/}g;

        # Security: Split path and validate each component
        # Use -1 limit to preserve trailing empty strings
        my @components = split m{/}, $path, -1;
        for my $component (@components) {
            # Block components with 2+ dots (.. , ..., ....)
            if ($component =~ /^\.{2,}$/) {
                await $self->_send_error($send, 403, 'Forbidden');
                return;
            }
            # Block hidden files (dotfiles) - components starting with .
            if ($component =~ /^\./ && $component ne '') {
                await $self->_send_error($send, 403, 'Forbidden');
                return;
            }
        }

        # Build file path using File::Spec for portability
        $path =~ s{^/+}{};
        my $file_path = File::Spec->catfile($root, $path);

        # Check for index files if directory
        if (-d $file_path) {
            for my $index (@{$self->{index}}) {
                my $index_path = File::Spec->catfile($file_path, $index);
                if (-f $index_path) {
                    $file_path = $index_path;
                    last;
                }
            }
        }

        unless (-f $file_path && -r $file_path) {
            await $self->_send_error($send, 404, 'Not Found');
            return;
        }

        # Security: Verify resolved path stays within root (prevents symlink escape)
        my $real_path = Cwd::realpath($file_path);
        unless ($real_path && index($real_path, $root) == 0) {
            await $self->_send_error($send, 403, 'Forbidden');
            return;
        }

        my @stat = stat($file_path);
        my $size = $stat[7];
        my $mtime = $stat[9];
        my $etag = '"' . md5_hex("$mtime-$size") . '"';

        # Check If-None-Match
        my $if_none_match = $self->_get_header($scope, 'if-none-match');
        if ($if_none_match && $if_none_match eq $etag) {
            await $send->({
                type => 'http.response.start',
                status => 304,
                headers => [['etag', $etag]],
            });
            await $send->({ type => 'http.response.body', body => '', more => 0 });
            return;
        }

        # Determine MIME type
        my ($ext) = $file_path =~ /\.([^.]+)$/;
        my $content_type = $MIME_TYPES{lc($ext // '')} // $self->{default_type};

        # Check for Range request (only if handle_ranges is enabled)
        my $range = $self->{handle_ranges} ? $self->_get_header($scope, 'range') : undef;
        if ($range && $range =~ /bytes=(\d*)-(\d*)/) {
            my ($start, $end) = ($1, $2);
            $start = 0 if $start eq '';
            $end = $size - 1 if $end eq '' || $end >= $size;

            if ($start > $end || $start >= $size) {
                await $self->_send_error($send, 416, 'Range Not Satisfiable');
                return;
            }

            my $length = $end - $start + 1;

            await $send->({
                type => 'http.response.start',
                status => 206,
                headers => [
                    ['content-type', $content_type],
                    ['content-length', $length],
                    ['content-range', "bytes $start-$end/$size"],
                    ['accept-ranges', 'bytes'],
                    ['etag', $etag],
                ],
            });

            # Use file response with offset/length for efficient streaming
            if ($method eq 'HEAD') {
                await $send->({ type => 'http.response.body', body => '', more => 0 });
            }
            else {
                await $send->({
                    type   => 'http.response.body',
                    file   => $file_path,
                    offset => $start,
                    length => $length,
                });
            }
            return;
        }

        # Full file response
        await $send->({
            type => 'http.response.start',
            status => 200,
            headers => [
                ['content-type', $content_type],
                ['content-length', $size],
                ['accept-ranges', 'bytes'],
                ['etag', $etag],
            ],
        });

        # Use file response for efficient streaming (sendfile or worker pool)
        if ($method eq 'HEAD') {
            await $send->({ type => 'http.response.body', body => '', more => 0 });
        }
        else {
            await $send->({
                type => 'http.response.body',
                file => $file_path,
            });
        }
    };
}

sub _get_header {
    my ($self, $scope, $name) = @_;

    $name = lc($name);
    for my $h (@{$scope->{headers} // []}) {
        return $h->[1] if lc($h->[0]) eq $name;
    }
    return;
}

async sub _send_error {
    my ($self, $send, $status, $message) = @_;

    await $send->({
        type => 'http.response.start',
        status => $status,
        headers => [['content-type', 'text/plain'], ['content-length', length($message)]],
    });
    await $send->({ type => 'http.response.body', body => $message, more => 0 });
}

1;

__END__

=head1 CONFIGURATION

=over 4

=item * root - Root directory for files

=item * default_type - Default MIME type (default: application/octet-stream)

=item * index - Index file names (default: [index.html, index.htm])

=item * handle_ranges - Process Range headers (default: 1)

When enabled (default), the app processes Range request headers and returns
206 Partial Content responses. Set to 0 to ignore Range headers and always
return the full file.

B<When to disable Range handling:>

When using L<PAGI::Middleware::XSendfile> with a reverse proxy (Nginx, Apache),
you should disable range handling. The proxy will handle Range requests more
efficiently using its native sendfile implementation:

    my $app = PAGI::App::File->new(
        root          => '/var/www/files',
        handle_ranges => 0,  # Let proxy handle Range requests
    )->to_app;

    my $wrapped = builder {
        enable 'XSendfile',
            type    => 'X-Accel-Redirect',
            mapping => { '/var/www/files/' => '/protected/' };
        $app;
    };

With this setup, your app always sends the full file path via X-Sendfile header,
and Nginx handles Range requests natively (which is faster than doing it in Perl).

=back

=cut
