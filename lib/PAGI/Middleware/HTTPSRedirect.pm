package PAGI::Middleware::HTTPSRedirect;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;

=head1 NAME

PAGI::Middleware::HTTPSRedirect - Force HTTPS redirect middleware

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'HTTPSRedirect';
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::HTTPSRedirect redirects HTTP requests to HTTPS.
Useful for enforcing secure connections in production.

=head1 CONFIGURATION

=over 4

=item * redirect_code (default: 301)

HTTP status code for redirects. Use 302 for temporary redirects.

=item * exclude (optional)

Arrayref of paths to exclude from redirect (e.g., health checks).

=item * hsts (default: 0)

If true, add Strict-Transport-Security header.

=item * hsts_max_age (default: 31536000)

HSTS max-age in seconds (1 year default).

=back

=cut

sub _init {
    my ($self, $config) = @_;

    $self->{redirect_code} = $config->{redirect_code} // 301;
    $self->{exclude} = $config->{exclude} // [];
    $self->{hsts} = $config->{hsts} // 0;
    $self->{hsts_max_age} = $config->{hsts_max_age} // 31536000;
}

sub wrap {
    my ($self, $app) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        my $scheme = $scope->{scheme} // 'http';

        # Already HTTPS
        if ($scheme eq 'https') {
            # Add HSTS header if enabled
            if ($self->{hsts}) {
                my $wrapped_send = async sub  {
        my ($event) = @_;
                    if ($event->{type} eq 'http.response.start') {
                        my @headers = @{$event->{headers} // []};
                        push @headers, [
                            'Strict-Transport-Security',
                            "max-age=$self->{hsts_max_age}; includeSubDomains"
                        ];
                        await $send->({
                            %$event,
                            headers => \@headers,
                        });
                        return;
                    }
                    await $send->($event);
                };
                await $app->($scope, $receive, $wrapped_send);
            } else {
                await $app->($scope, $receive, $send);
            }
            return;
        }

        # Check exclusions
        if ($self->_is_excluded($scope->{path})) {
            await $app->($scope, $receive, $send);
            return;
        }

        # Build HTTPS URL
        my $host = $self->_get_header($scope, 'host') // 'localhost';
        my $path = $scope->{path} // '/';
        my $query = $scope->{query_string};

        my $url = "https://$host$path";
        $url .= "?$query" if defined $query && $query ne '';

        await $self->_send_redirect($send, $url);
    };
}

sub _is_excluded {
    my ($self, $path) = @_;

    for my $pattern (@{$self->{exclude}}) {
        if (ref $pattern eq 'Regexp') {
            return 1 if $path =~ $pattern;
        } else {
            return 1 if $path eq $pattern;
        }
    }
    return 0;
}

async sub _send_redirect {
    my ($self, $send, $location) = @_;

    my $status = $self->{redirect_code};
    my $body = "Redirecting to $location";

    await $send->({
        type    => 'http.response.start',
        status  => $status,
        headers => [
            ['Content-Type', 'text/plain'],
            ['Content-Length', length($body)],
            ['Location', $location],
        ],
    });
    await $send->({
        type => 'http.response.body',
        body => $body,
        more => 0,
    });
}

sub _get_header {
    my ($self, $scope, $name) = @_;

    $name = lc($name);
    for my $h (@{$scope->{headers} // []}) {
        return $h->[1] if lc($h->[0]) eq $name;
    }
    return;
}

1;

__END__

=head1 NOTES

This middleware checks C<$scope-E<gt>{scheme}> to determine if the request
is already using HTTPS. Make sure your server sets this correctly, especially
when behind a reverse proxy (use ReverseProxy middleware).

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

L<PAGI::Middleware::ReverseProxy> - Handle X-Forwarded headers

=cut
