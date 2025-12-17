package PAGI::App::File;

use strict;
use warnings;
use experimental 'signatures';
use Future::AsyncAwait;
use Digest::MD5 qw(md5_hex);
use IO::Async::Loop;
use PAGI::Util::AsyncFile;

=head1 NAME

PAGI::App::File - Serve static files

=head1 SYNOPSIS

    use PAGI::App::File;

    my $app = PAGI::App::File->new(
        root => '/var/www/static',
    )->to_app;

=head1 DESCRIPTION

PAGI::App::File serves static files from a configured root directory.
Supports ETag caching, Range requests, and path traversal prevention.

=cut

our %MIME_TYPES = (
    html => 'text/html',
    htm  => 'text/html',
    css  => 'text/css',
    js   => 'application/javascript',
    json => 'application/json',
    xml  => 'application/xml',
    txt  => 'text/plain',
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

sub new ($class, %args) {
    my $self = bless {
        root         => $args{root} // '.',
        default_type => $args{default_type} // 'application/octet-stream',
        index        => $args{index} // ['index.html', 'index.htm'],
    }, $class;
    return $self;
}

sub to_app ($self) {
    my $root = $self->{root};

    return async sub ($scope, $receive, $send) {
        die "Unsupported scope type: $scope->{type}" if $scope->{type} ne 'http';

        my $method = uc($scope->{method} // '');
        unless ($method eq 'GET' || $method eq 'HEAD') {
            await $self->_send_error($send, 405, 'Method Not Allowed');
            return;
        }

        my $path = $scope->{path} // '/';

        # Prevent path traversal
        if ($path =~ /\.\./) {
            await $self->_send_error($send, 403, 'Forbidden');
            return;
        }

        # Normalize path
        $path =~ s{^/+}{};
        my $file_path = "$root/$path";

        # Check for index files if directory
        if (-d $file_path) {
            for my $index (@{$self->{index}}) {
                my $index_path = "$file_path/$index";
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

        # Check for Range request
        my $range = $self->_get_header($scope, 'range');
        if ($range && $range =~ /bytes=(\d*)-(\d*)/) {
            my ($start, $end) = ($1, $2);
            $start = 0 if $start eq '';
            $end = $size - 1 if $end eq '' || $end >= $size;

            if ($start > $end || $start >= $size) {
                await $self->_send_error($send, 416, 'Range Not Satisfiable');
                return;
            }

            my $length = $end - $start + 1;
            my $content = '';

            if ($method ne 'HEAD') {
                # Use non-blocking async file I/O via IO::Async::Loop singleton
                my $loop = IO::Async::Loop->new;
                eval {
                    my $full_content = await PAGI::Util::AsyncFile->read_file($loop, $file_path);
                    $content = substr($full_content, $start, $length);
                };
                if ($@) {
                    await $self->_send_error($send, 500, 'Internal Server Error');
                    return;
                }
            }

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

            await $send->({ type => 'http.response.body', body => $content, more => 0 });
            return;
        }

        # Full file response
        my $content = '';
        if ($method ne 'HEAD') {
            # Use non-blocking async file I/O via IO::Async::Loop singleton
            my $loop = IO::Async::Loop->new;
            eval {
                $content = await PAGI::Util::AsyncFile->read_file($loop, $file_path);
            };
            if ($@) {
                await $self->_send_error($send, 500, 'Internal Server Error');
                return;
            }
        }

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
        await $send->({ type => 'http.response.body', body => $content, more => 0 });
    };
}

sub _get_header ($self, $scope, $name) {
    $name = lc($name);
    for my $h (@{$scope->{headers} // []}) {
        return $h->[1] if lc($h->[0]) eq $name;
    }
    return;
}

async sub _send_error ($self, $send, $status, $message) {
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

=back

=cut
