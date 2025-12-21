package PAGI::Middleware::Healthcheck;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;
use JSON::PP ();

=head1 NAME

PAGI::Middleware::Healthcheck - Health check endpoint middleware

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'Healthcheck',
            path => '/health',
            checks => {
                database => sub { check_db_connection() },
                cache    => sub { check_redis() },
            };
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::Healthcheck provides a health check endpoint for
load balancers and monitoring systems. Returns JSON status information.

=head1 CONFIGURATION

=over 4

=item * path (default: '/health')

Path for the health check endpoint.

=item * live_path (optional)

Separate path for liveness probe (always returns 200 if server is running).

=item * ready_path (optional)

Separate path for readiness probe (runs all checks).

=item * checks (optional)

Hashref of named health checks. Each check is a coderef that returns
true (healthy) or false (unhealthy), or throws an exception.

=item * include_details (default: 1)

Include individual check results in response.

=back

=cut

sub _init {
    my ($self, $config) = @_;

    $self->{path} = $config->{path} // '/health';
    $self->{live_path} = $config->{live_path};
    $self->{ready_path} = $config->{ready_path};
    $self->{checks} = $config->{checks} // {};
    $self->{include_details} = $config->{include_details} // 1;
}

sub wrap {
    my ($self, $app) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        my $path = $scope->{path};

        # Liveness probe (just check server is responding)
        if (defined $self->{live_path} && $path eq $self->{live_path}) {
            await $self->_send_live($send);
            return;
        }

        # Readiness probe (run all checks)
        if (defined $self->{ready_path} && $path eq $self->{ready_path}) {
            await $self->_send_ready($send);
            return;
        }

        # Main health check endpoint
        if ($path eq $self->{path}) {
            await $self->_send_health($send);
            return;
        }

        # Not a health check path, pass through
        await $app->($scope, $receive, $send);
    };
}

async sub _send_live {
    my ($self, $send) = @_;

    my $body = JSON::PP::encode_json({ status => 'ok' });

    await $send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [
            ['Content-Type', 'application/json'],
            ['Content-Length', length($body)],
            ['Cache-Control', 'no-cache, no-store'],
        ],
    });
    await $send->({
        type => 'http.response.body',
        body => $body,
        more => 0,
    });
}

async sub _send_ready {
    my ($self, $send) = @_;

    my ($healthy, $results) = $self->_run_checks();

    my $response = {
        status => $healthy ? 'ok' : 'error',
    };
    $response->{checks} = $results if $self->{include_details};

    my $body = JSON::PP::encode_json($response);
    my $status = $healthy ? 200 : 503;

    await $send->({
        type    => 'http.response.start',
        status  => $status,
        headers => [
            ['Content-Type', 'application/json'],
            ['Content-Length', length($body)],
            ['Cache-Control', 'no-cache, no-store'],
        ],
    });
    await $send->({
        type => 'http.response.body',
        body => $body,
        more => 0,
    });
}

async sub _send_health {
    my ($self, $send) = @_;

    my ($healthy, $results) = $self->_run_checks();

    my $response = {
        status    => $healthy ? 'ok' : 'error',
        timestamp => time(),
    };
    $response->{checks} = $results if $self->{include_details} && keys %{$self->{checks}};

    my $body = JSON::PP::encode_json($response);
    my $status = $healthy ? 200 : 503;

    await $send->({
        type    => 'http.response.start',
        status  => $status,
        headers => [
            ['Content-Type', 'application/json'],
            ['Content-Length', length($body)],
            ['Cache-Control', 'no-cache, no-store'],
        ],
    });
    await $send->({
        type => 'http.response.body',
        body => $body,
        more => 0,
    });
}

sub _run_checks {
    my ($self) = @_;

    my %results;
    my $all_healthy = 1;

    for my $name (sort keys %{$self->{checks}}) {
        my $check = $self->{checks}{$name};
        my $result = { status => 'ok' };

        eval {
            my $ok = $check->();
            unless ($ok) {
                $result->{status} = 'error';
                $all_healthy = 0;
            }
        };
        if ($@) {
            $result->{status} = 'error';
            $result->{message} = "$@";
            $result->{message} =~ s/\s+$//;
            $all_healthy = 0;
        }

        $results{$name} = $result;
    }

    return ($all_healthy, \%results);
}

1;

__END__

=head1 RESPONSE FORMAT

Health check responses are JSON:

    {
        "status": "ok",
        "timestamp": 1234567890,
        "checks": {
            "database": { "status": "ok" },
            "cache": { "status": "error", "message": "Connection refused" }
        }
    }

=head1 HTTP STATUS CODES

=over 4

=item * 200 - All checks passed

=item * 503 - One or more checks failed

=back

=head1 KUBERNETES PROBES

Configure separate endpoints for Kubernetes:

    enable 'Healthcheck',
        path       => '/health',
        live_path  => '/healthz',
        ready_path => '/ready',
        checks     => { db => sub { ... } };

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

=cut
