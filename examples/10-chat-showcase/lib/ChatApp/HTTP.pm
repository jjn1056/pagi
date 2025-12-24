package ChatApp::HTTP;

use strict;
use warnings;

use Future::AsyncAwait;
use JSON::MaybeXS;
use File::Spec;
use File::Basename qw(dirname);
use PAGI::App::Router;

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

# API Handlers
sub _rooms_handler {
    return async sub {
        my ($scope, $receive, $send) = @_;
        my $rooms = get_all_rooms();
        my $data = [
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
        await _send_json($send, 200, $data);
    };
}

sub _room_history_handler {
    return async sub {
        my ($scope, $receive, $send) = @_;
        my $room_name = $scope->{path_params}{name};
        my $room = get_room($room_name);
        if ($room) {
            my $data = get_room_messages($room_name, 100);
            await _send_json($send, 200, $data);
        } else {
            await _send_json($send, 404, { error => 'Room not found' });
        }
    };
}

sub _room_users_handler {
    return async sub {
        my ($scope, $receive, $send) = @_;
        my $room_name = $scope->{path_params}{name};
        my $room = get_room($room_name);
        if ($room) {
            my $data = get_room_users($room_name);
            await _send_json($send, 200, $data);
        } else {
            await _send_json($send, 404, { error => 'Room not found' });
        }
    };
}

sub _stats_handler {
    return async sub {
        my ($scope, $receive, $send) = @_;
        my $data = get_stats();
        await _send_json($send, 200, $data);
    };
}

async sub _send_json {
    my ($send, $status, $data) = @_;
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

sub handler {
    my $router = PAGI::App::Router->new;

    # API routes
    $router->get('/api/rooms' => _rooms_handler());
    $router->get('/api/room/:name/history' => _room_history_handler());
    $router->get('/api/room/:name/users' => _room_users_handler());
    $router->get('/api/stats' => _stats_handler());

    my $api_app = $router->to_app;

    return async sub {
        my ($scope, $receive, $send) = @_;
        my $path = $scope->{path} // '/';

        # Route API requests through router
        if ($path =~ m{^/api/}) {
            return await $api_app->($scope, $receive, $send);
        }

        # Serve static files
        return await _serve_static($scope, $receive, $send, $path);
    };
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

=head1 NAME

ChatApp::HTTP - HTTP request handler for the chat application

=head1 DESCRIPTION

Handles HTTP requests including static file serving and API endpoints.
Uses L<PAGI::App::Router> for declarative API routing with parameter capture.

=head2 API Endpoints

=over

=item GET /api/rooms

Returns list of all rooms with user counts.

=item GET /api/room/:name/history

Returns message history for a room. The C<:name> parameter is captured
by the router and available in C<< $scope->{path_params}{name} >>.

=item GET /api/room/:name/users

Returns list of users in a room.

=item GET /api/stats

Returns server statistics.

=back

=head1 SEE ALSO

L<PAGI::App::Router>

=cut
