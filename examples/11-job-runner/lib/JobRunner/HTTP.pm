package JobRunner::HTTP;

use strict;
use warnings;

use Future::AsyncAwait;
use JSON::MaybeXS;
use File::Spec;
use File::Basename;

use JobRunner::Queue qw(
    create_job get_job get_all_jobs cancel_job
    get_queue_stats clear_completed_jobs
);
use JobRunner::Jobs qw(get_job_types get_job_type validate_job_params);
use JobRunner::Worker qw(get_worker_stats);

my $JSON = JSON::MaybeXS->new->utf8->canonical->allow_nonref;

# MIME types for static files
my %MIME_TYPES = (
    '.html' => 'text/html; charset=utf-8',
    '.css'  => 'text/css; charset=utf-8',
    '.js'   => 'application/javascript; charset=utf-8',
    '.json' => 'application/json; charset=utf-8',
    '.png'  => 'image/png',
    '.jpg'  => 'image/jpeg',
    '.gif'  => 'image/gif',
    '.svg'  => 'image/svg+xml',
    '.ico'  => 'image/x-icon',
);

# Path to public directory
my $PUBLIC_DIR;

sub set_public_dir {
    my ($dir) = @_;

    $PUBLIC_DIR = $dir;
}

sub handler {
    return async sub  {
        my ($scope, $receive, $send) = @_;
        my $method = $scope->{method};
        my $path = $scope->{path};

        # Route to appropriate handler
        my ($status, $headers, $body);

        eval {
            if ($path =~ m{^/api/}) {
                ($status, $headers, $body) = await _handle_api($method, $path, $scope, $receive);
            } else {
                ($status, $headers, $body) = await _handle_static($path);
            }
        };

        if ($@) {
            my $error = $@;
            warn "HTTP Error: $error";
            ($status, $headers, $body) = (
                500,
                [['content-type', 'application/json']],
                $JSON->encode({ error => "Internal server error", details => "$error" })
            );
        }

        # Send response
        await $send->({
            type    => 'http.response.start',
            status  => $status,
            headers => $headers,
        });

        await $send->({
            type => 'http.response.body',
            body => $body,
            more => 0,
        });
    };
}

#
# API Handlers
#

async sub _handle_api {
    my ($method, $path, $scope, $receive) = @_;

    # Parse path
    my @parts = split '/', $path;
    shift @parts;  # Remove empty first element
    shift @parts;  # Remove 'api'

    my $resource = $parts[0] // '';

    # GET /api/stats
    if ($method eq 'GET' && $path eq '/api/stats') {
        return _json_response(200, {
            queue  => get_queue_stats(),
            worker => get_worker_stats(),
        });
    }

    # GET /api/job-types
    if ($method eq 'GET' && $path eq '/api/job-types') {
        return _json_response(200, get_job_types());
    }

    # Job endpoints
    if ($resource eq 'jobs') {
        my $job_id = $parts[1];

        # GET /api/jobs
        if ($method eq 'GET' && !$job_id) {
            return _json_response(200, get_all_jobs());
        }

        # POST /api/jobs
        if ($method eq 'POST' && !$job_id) {
            return await _create_job($scope, $receive);
        }

        # GET /api/jobs/:id
        if ($method eq 'GET' && $job_id && !$parts[2]) {
            return _get_job($job_id);
        }

        # DELETE /api/jobs/:id
        if ($method eq 'DELETE' && $job_id && !$parts[2]) {
            return _cancel_job($job_id);
        }

        # POST /api/jobs/clear-completed
        if ($method eq 'POST' && $job_id eq 'clear-completed') {
            my $count = clear_completed_jobs();
            return _json_response(200, { cleared => $count });
        }
    }

    # Not found
    return _json_response(404, { error => "Not found: $path" });
}

async sub _create_job {
    my ($scope, $receive) = @_;

    # Read request body
    my $body = '';
    while (1) {
        my $event = await $receive->();
        if ($event->{type} eq 'http.request') {
            $body .= $event->{body} // '';
            last unless $event->{more};
        } else {
            last;
        }
    }

    # Parse JSON
    my $data = eval { $JSON->decode($body) };
    unless ($data && ref $data eq 'HASH') {
        return _json_response(400, { error => "Invalid JSON body" });
    }

    my $job_type = $data->{job_type};
    my $params = $data->{params} // {};

    # Validate job type
    unless ($job_type) {
        return _json_response(400, { error => "Missing 'job_type' field" });
    }

    # Validate parameters
    my ($valid, $error, $normalized_params) = validate_job_params($job_type, $params);
    unless ($valid) {
        return _json_response(400, { error => $error });
    }

    # Create job
    my $job_id = create_job($job_type, $normalized_params);
    my $job = get_job($job_id);

    return _json_response(201, {
        id         => $job->{id},
        type       => $job->{type},
        params     => $job->{params},
        status     => $job->{status},
        created_at => $job->{created_at},
    });
}

sub _get_job {
    my ($job_id) = @_;

    my $job = get_job($job_id);

    unless ($job) {
        return _json_response(404, { error => "Job not found: $job_id" });
    }

    return _json_response(200, $job);
}

sub _cancel_job {
    my ($job_id) = @_;

    my $job = get_job($job_id);

    unless ($job) {
        return _json_response(404, { error => "Job not found: $job_id" });
    }

    my $success = cancel_job($job_id);

    if ($success) {
        return _json_response(200, { success => JSON::MaybeXS::true, job_id => $job_id });
    } else {
        return _json_response(400, {
            error => "Cannot cancel job in status: $job->{status}",
            job_id => $job_id,
        });
    }
}

#
# Static File Handler
#

async sub _handle_static {
    my ($path) = @_;

    # Default to index.html
    $path = '/index.html' if $path eq '/';

    # Security: prevent directory traversal
    return _json_response(403, { error => "Forbidden" })
        if $path =~ /\.\./;

    # Build file path
    my $file_path = File::Spec->catfile($PUBLIC_DIR, $path);

    # Check if file exists
    unless (-f $file_path) {
        return _json_response(404, { error => "Not found: $path" });
    }

    # Read file
    my $content;
    {
        local $/;
        open my $fh, '<:raw', $file_path or do {
            return _json_response(500, { error => "Cannot read file" });
        };
        $content = <$fh>;
        close $fh;
    }

    # Determine MIME type
    my $ext = lc((fileparse($file_path, qr/\.[^.]*/))[2]);
    my $mime_type = $MIME_TYPES{$ext} // 'application/octet-stream';

    return (
        200,
        [['content-type', $mime_type]],
        $content
    );
}

#
# Response Helpers
#

sub _json_response {
    my ($status, $data) = @_;

    return (
        $status,
        [['content-type', 'application/json']],
        $JSON->encode($data)
    );
}

1;

__END__

# NAME

JobRunner::HTTP - REST API and static file handler

# DESCRIPTION

Handles HTTP requests for the Job Runner application.

## API Endpoints

- **GET /api/stats** - Queue and worker statistics
- **GET /api/job-types** - Available job types
- **GET /api/jobs** - List all jobs
- **POST /api/jobs** - Create a new job
- **GET /api/jobs/:id** - Get job details
- **DELETE /api/jobs/:id** - Cancel a job
- **POST /api/jobs/clear-completed** - Clear finished jobs
