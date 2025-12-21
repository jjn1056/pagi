package PAGI::Middleware::AccessLog;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;
use Time::HiRes qw(time);
use POSIX qw(strftime);

=head1 NAME

PAGI::Middleware::AccessLog - Request logging middleware

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'AccessLog',
            logger => sub { print STDERR @_ },
            format => 'combined';
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::AccessLog logs HTTP requests in configurable formats.
It captures client IP, method, path, status, response size, and timing.

=head1 CONFIGURATION

=over 4

=item * logger (default: warns to STDERR)

A coderef that receives the formatted log line.

=item * format (default: 'combined')

Log format: 'combined', 'common', or 'tiny'.

=back

=cut

sub _init {
    my ($self, $config) = @_;

    $self->{logger} = $config->{logger} // sub { warn @_ };
    $self->{format} = $config->{format} // 'combined';
}

sub wrap {
    my ($self, $app) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        # Only log HTTP requests
        if ($scope->{type} ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        my $start_time = time();
        my $status;
        my $response_size = 0;

        # Intercept send to capture response info
        my $wrapped_send = async sub  {
        my ($event) = @_;
            if ($event->{type} eq 'http.response.start') {
                $status = $event->{status};
            } elsif ($event->{type} eq 'http.response.body') {
                $response_size += length($event->{body} // '');
            }
            await $send->($event);
        };

        # Run the inner app
        eval {
            await $app->($scope, $receive, $wrapped_send);
            1;
        } or do {
            my $error = $@;
            $status //= 500;
            $self->_log_request($scope, $status, $response_size, $start_time);
            die $error;
        };

        # Log the request
        $self->_log_request($scope, $status, $response_size, $start_time);
    };
}

sub _log_request {
    my ($self, $scope, $status, $size, $start_time) = @_;

    my $duration = time() - $start_time;
    my $line = $self->_format_log($scope, $status, $size, $duration);
    $self->{logger}->($line);
}

sub _format_log {
    my ($self, $scope, $status, $size, $duration) = @_;

    my $format = $self->{format};

    # Extract info from scope
    my $client_ip = $scope->{client}[0] // '-';
    my $method = $scope->{method} // '-';
    my $path = $scope->{path} // '/';
    my $query = $scope->{query_string};
    my $full_path = defined $query && $query ne '' ? "$path?$query" : $path;
    my $protocol = 'HTTP/' . ($scope->{http_version} // '1.1');

    # Get headers
    my $referer = '-';
    my $user_agent = '-';
    for my $h (@{$scope->{headers} // []}) {
        my $name = lc($h->[0]);
        if ($name eq 'referer') {
            $referer = $h->[1];
        } elsif ($name eq 'user-agent') {
            $user_agent = $h->[1];
        }
    }

    # Format timestamp
    my $timestamp = strftime('%d/%b/%Y:%H:%M:%S %z', localtime());

    $status //= 0;
    $size //= 0;

    if ($format eq 'combined') {
        # Combined Log Format (Apache/nginx style)
        return sprintf(
            qq{%s - - [%s] "%s %s %s" %d %d "%s" "%s" %.3fs\n},
            $client_ip, $timestamp, $method, $full_path, $protocol,
            $status, $size, $referer, $user_agent, $duration
        );
    } elsif ($format eq 'common') {
        # Common Log Format
        return sprintf(
            qq{%s - - [%s] "%s %s %s" %d %d\n},
            $client_ip, $timestamp, $method, $full_path, $protocol,
            $status, $size
        );
    } else {
        # Tiny format
        return sprintf(
            "%s %s %d %.3fs\n",
            $method, $full_path, $status, $duration
        );
    }
}

1;

__END__

=head1 LOG FORMATS

=head2 combined (default)

Apache/nginx combined log format:

    127.0.0.1 - - [01/Jan/2024:12:00:00 +0000] "GET /path HTTP/1.1" 200 1234 "-" "Mozilla/5.0" 0.005s

=head2 common

Apache common log format:

    127.0.0.1 - - [01/Jan/2024:12:00:00 +0000] "GET /path HTTP/1.1" 200 1234

=head2 tiny

Minimal format:

    GET /path 200 0.005s

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

=cut
