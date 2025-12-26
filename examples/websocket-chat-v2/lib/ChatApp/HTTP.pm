package ChatApp::HTTP;

use strict;
use warnings;

use Future::AsyncAwait;
use JSON::MaybeXS;
use File::Spec;
use File::Basename qw(dirname);

use ChatApp::State qw(
    get_all_rooms get_room get_room_messages get_room_users get_stats
);

my $JSON = JSON::MaybeXS->new->utf8->canonical;

# Get the public directory path
my $PUBLIC_DIR = File::Spec->catdir(dirname(__FILE__), '..', '..', 'public');

# MIME types for static files
my %MIME_TYPES = (
    html => 'text/html; charset=utf-8',
    css  => 'text/css; charset=utf-8',
    js   => 'application/javascript; charset=utf-8',
    json => 'application/json; charset=utf-8',
    png  => 'image/png',
    jpg  => 'image/jpeg',
    jpeg => 'image/jpeg',
    gif  => 'image/gif',
    svg  => 'image/svg+xml',
    ico  => 'image/x-icon',
    woff => 'font/woff',
    woff2=> 'font/woff2',
);

sub handler {
    return async sub  {
        my ($scope, $receive, $send) = @_;
        my $path = $scope->{path} // '/';
        my $method = $scope->{method} // 'GET';

        # Route API requests
        if ($path =~ m{^/api/}) {
            return await _handle_api($scope, $receive, $send, $path, $method);
        }

        # Serve static files
        return await _serve_static($scope, $receive, $send, $path);
    };
}

async sub _handle_api {
    my ($scope, $receive, $send, $path, $method) = @_;

    my ($status, $data);

    if ($path eq '/api/rooms' && $method eq 'GET') {
        my $rooms = get_all_rooms();
        $data = [
            map {
                {
                    name       => $_->{name},
                    users      => scalar(keys %{$_->{users}}),
                    created_at => $_->{created_at},
                }
            }
            sort { $a->{name} cmp $b->{name} }
            values %$rooms
        ];
        $status = 200;
    }
    elsif ($path =~ m{^/api/room/([^/]+)/history$} && $method eq 'GET') {
        my $room_name = $1;
        my $room = get_room($room_name);
        if ($room) {
            $data = get_room_messages($room_name, 100);
            $status = 200;
        } else {
            $data = { error => 'Room not found' };
            $status = 404;
        }
    }
    elsif ($path =~ m{^/api/room/([^/]+)/users$} && $method eq 'GET') {
        my $room_name = $1;
        my $room = get_room($room_name);
        if ($room) {
            $data = get_room_users($room_name);
            $status = 200;
        } else {
            $data = { error => 'Room not found' };
            $status = 404;
        }
    }
    elsif ($path eq '/api/stats' && $method eq 'GET') {
        $data = get_stats();
        $status = 200;
    }
    else {
        $data = { error => 'Not found' };
        $status = 404;
    }

    my $body = $JSON->encode($data);

    await $send->({
        type    => 'http.response.start',
        status  => $status,
        headers => [
            ['content-type', 'application/json; charset=utf-8'],
            ['content-length', length($body)],
            ['cache-control', 'no-cache'],
        ],
    });

    await $send->({
        type => 'http.response.body',
        body => $body,
        more => 0,
    });
}

async sub _serve_static {
    my ($scope, $receive, $send, $path) = @_;

    # Default to index.html
    $path = '/index.html' if $path eq '/';

    # Security: prevent directory traversal
    $path =~ s/\.\.//g;
    $path =~ s|//+|/|g;

    my $file_path = File::Spec->catfile($PUBLIC_DIR, $path);

    # Check if file exists and is readable
    unless (-f $file_path && -r $file_path) {
        return await _send_404($send);
    }

    # Get file extension and MIME type
    my ($ext) = $file_path =~ /\.(\w+)$/;
    my $content_type = $MIME_TYPES{lc($ext // '')} // 'application/octet-stream';

    # Read file content
    my $content;
    {
        open my $fh, '<:raw', $file_path or return await _send_500($send);
        local $/;
        $content = <$fh>;
        close $fh;
    }

    # Send response
    await $send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [
            ['content-type', $content_type],
            ['content-length', length($content)],
            ['cache-control', 'public, max-age=3600'],
        ],
    });

    await $send->({
        type => 'http.response.body',
        body => $content,
        more => 0,
    });
}

async sub _send_404 {
    my ($send) = @_;

    my $body = '{"error":"Not found"}';
    await $send->({
        type    => 'http.response.start',
        status  => 404,
        headers => [
            ['content-type', 'application/json'],
            ['content-length', length($body)],
        ],
    });
    await $send->({
        type => 'http.response.body',
        body => $body,
        more => 0,
    });
}

async sub _send_500 {
    my ($send) = @_;

    my $body = '{"error":"Internal server error"}';
    await $send->({
        type    => 'http.response.start',
        status  => 500,
        headers => [
            ['content-type', 'application/json'],
            ['content-length', length($body)],
        ],
    });
    await $send->({
        type => 'http.response.body',
        body => $body,
        more => 0,
    });
}

1;

__END__

# NAME

ChatApp::HTTP - HTTP request handler for the chat application

# DESCRIPTION

Handles HTTP requests including static file serving and API endpoints.

## API Endpoints

- **GET /api/rooms** - Returns list of all rooms with user counts.
- **GET /api/room/:name/history** - Returns message history for a room.
- **GET /api/room/:name/users** - Returns list of users in a room.
- **GET /api/stats** - Returns server statistics.
