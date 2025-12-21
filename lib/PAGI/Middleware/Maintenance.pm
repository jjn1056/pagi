package PAGI::Middleware::Maintenance;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;

=head1 NAME

PAGI::Middleware::Maintenance - Serve maintenance page when enabled

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'Maintenance',
            enabled => $ENV{MAINTENANCE_MODE},
            bypass_ips => ['10.0.0.0/8'],
            retry_after => 3600;
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::Maintenance serves a 503 Service Unavailable page
when maintenance mode is enabled. Supports IP-based bypass for admins.

=head1 CONFIGURATION

=over 4

=item * enabled (default: 0)

Enable maintenance mode. Can be a coderef for dynamic checking.

=item * bypass_ips (default: [])

Arrayref of IPs or CIDR ranges that bypass maintenance mode.

=item * bypass_paths (default: [])

Arrayref of paths that bypass maintenance mode (e.g., health checks).

=item * retry_after (optional)

Seconds until maintenance expected to end. Sets Retry-After header.

=item * content_type (default: 'text/html')

Content-Type of the maintenance page.

=item * body (default: built-in HTML page)

Custom maintenance page body.

=back

=cut

sub _init {
    my ($self, $config) = @_;

    $self->{enabled} = $config->{enabled} // 0;
    $self->{bypass_ips} = $config->{bypass_ips} // [];
    $self->{bypass_paths} = $config->{bypass_paths} // [];
    $self->{retry_after} = $config->{retry_after};
    $self->{content_type} = $config->{content_type} // 'text/html';
    $self->{body} = $config->{body} // $self->_default_body();
}

sub wrap {
    my ($self, $app) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        # Check if maintenance is enabled
        my $enabled = ref $self->{enabled} eq 'CODE'
            ? $self->{enabled}->()
            : $self->{enabled};

        unless ($enabled) {
            await $app->($scope, $receive, $send);
            return;
        }

        # Check bypass conditions
        if ($self->_should_bypass($scope)) {
            await $app->($scope, $receive, $send);
            return;
        }

        # Serve maintenance page
        await $self->_send_maintenance($send);
    };
}

sub _should_bypass {
    my ($self, $scope) = @_;

    # Check bypass paths
    my $path = $scope->{path} // '';
    for my $bypass_path (@{$self->{bypass_paths}}) {
        if (ref $bypass_path eq 'Regexp') {
            return 1 if $path =~ $bypass_path;
        } else {
            return 1 if $path eq $bypass_path;
        }
    }

    # Check bypass IPs
    my $client_ip = $scope->{client}[0] // '';
    for my $bypass_ip (@{$self->{bypass_ips}}) {
        if ($bypass_ip =~ m{/}) {
            # CIDR notation
            return 1 if $self->_ip_in_cidr($client_ip, $bypass_ip);
        } else {
            # Exact match
            return 1 if $client_ip eq $bypass_ip;
        }
    }

    return 0;
}

sub _ip_in_cidr {
    my ($self, $ip, $cidr) = @_;

    my ($network, $bits) = split m{/}, $cidr;

    # Simple IPv4 check
    return 0 unless $ip =~ /^[\d.]+$/ && $network =~ /^[\d.]+$/;

    my $ip_num = $self->_ip_to_num($ip);
    my $net_num = $self->_ip_to_num($network);

    return 0 unless defined $ip_num && defined $net_num;

    my $mask = ~((1 << (32 - $bits)) - 1) & 0xFFFFFFFF;
    return ($ip_num & $mask) == ($net_num & $mask);
}

sub _ip_to_num {
    my ($self, $ip) = @_;

    my @octets = split /\./, $ip;
    return unless @octets == 4;
    return unless _all_valid_octets(@octets);
    return ($octets[0] << 24) + ($octets[1] << 16) + ($octets[2] << 8) + $octets[3];
}

sub _all_valid_octets {
    for (@_) {
        return 0 unless /^\d+$/ && $_ >= 0 && $_ <= 255;
    }
    return 1;
}

async sub _send_maintenance {
    my ($self, $send) = @_;

    my $body = $self->{body};

    my @headers = (
        ['Content-Type', $self->{content_type}],
        ['Content-Length', length($body)],
    );

    if (defined $self->{retry_after}) {
        push @headers, ['Retry-After', $self->{retry_after}];
    }

    await $send->({
        type    => 'http.response.start',
        status  => 503,
        headers => \@headers,
    });
    await $send->({
        type => 'http.response.body',
        body => $body,
        more => 0,
    });
}

sub _default_body {
    my ($self) = @_;

    return <<'HTML';
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Maintenance</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: #f5f5f5;
            display: flex;
            justify-content: center;
            align-items: center;
            min-height: 100vh;
            margin: 0;
        }
        .container {
            background: white;
            padding: 40px;
            border-radius: 8px;
            box-shadow: 0 2px 10px rgba(0,0,0,0.1);
            text-align: center;
            max-width: 500px;
        }
        h1 { color: #333; margin-bottom: 10px; }
        p { color: #666; line-height: 1.6; }
        .icon { font-size: 64px; margin-bottom: 20px; }
    </style>
</head>
<body>
    <div class="container">
        <div class="icon">🔧</div>
        <h1>Under Maintenance</h1>
        <p>We're currently performing scheduled maintenance. Please check back soon.</p>
    </div>
</body>
</html>
HTML
}

1;

__END__

=head1 DYNAMIC ENABLING

The C<enabled> option can be a coderef for dynamic maintenance mode:

    enable 'Maintenance',
        enabled => sub {
            return -e '/tmp/maintenance.flag';
        };

This allows enabling/disabling maintenance mode without restarting
the server.

=head1 BYPASS EXAMPLES

    enable 'Maintenance',
        enabled => 1,
        bypass_ips => [
            '127.0.0.1',      # localhost
            '10.0.0.0/8',     # internal network
        ],
        bypass_paths => [
            '/health',        # health checks
            qr{^/api/status}, # status API
        ];

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

L<PAGI::Middleware::Healthcheck> - Health check endpoints

=cut
