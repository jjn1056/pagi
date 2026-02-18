package PAGI::Middleware::CORS;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;

=head1 NAME

PAGI::Middleware::CORS - Cross-Origin Resource Sharing middleware

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'CORS',
            origins     => ['https://example.com', 'https://app.example.com'],
            methods     => ['GET', 'POST', 'PUT', 'DELETE'],
            headers     => ['Content-Type', 'Authorization'],
            credentials => 1,
            max_age     => 86400;
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::CORS implements Cross-Origin Resource Sharing (CORS)
for PAGI applications. It handles preflight OPTIONS requests and adds
the appropriate CORS headers to responses.

=head1 CONFIGURATION

=over 4

=item * origins (default: ['*'])

Array of allowed origins, or ['*'] for any origin.

=item * methods (default: ['GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'OPTIONS'])

Array of allowed HTTP methods.

=item * headers (default: ['Content-Type', 'Authorization', 'X-Requested-With'])

Array of allowed request headers.

=item * expose_headers (default: [])

Array of headers to expose to the client.

=item * credentials (default: 0)

If true, allow credentials (cookies, auth headers).

=item * max_age (default: 86400)

Max age for preflight cache in seconds.

=back

=cut

sub _init {
    my ($self, $config) = @_;

    $self->{origins}        = $config->{origins} // ['*'];
    $self->{methods}        = $config->{methods} // [qw(GET POST PUT DELETE PATCH OPTIONS)];
    $self->{headers}        = $config->{headers} // [qw(Content-Type Authorization X-Requested-With)];
    $self->{expose_headers} = $config->{expose_headers} // [];
    $self->{credentials}    = $config->{credentials} // 0;
    $self->{max_age}        = $config->{max_age} // 86400;

    if ($self->{credentials} && grep { $_ eq '*' } @{$self->{origins}}) {
        warn "PAGI::Middleware::CORS: wildcard origins ('*') with credentials "
           . "enabled reflects any Origin with Access-Control-Allow-Credentials. "
           . "This allows any website to make credentialed cross-origin requests. "
           . "Consider specifying explicit origins.\n";
    }
}

sub wrap {
    my ($self, $app) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        # Only handle HTTP requests
        if ($scope->{type} ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        # Get Origin header
        my $origin = $self->_get_header($scope, 'origin');

        # Check if this is a preflight request
        if ($scope->{method} eq 'OPTIONS' && $origin) {
            await $self->_handle_preflight($scope, $send, $origin);
            return;
        }

        # For actual requests, add CORS headers to response
        if ($origin && $self->_is_origin_allowed($origin)) {
            my $wrapped_send = async sub  {
        my ($event) = @_;
                if ($event->{type} eq 'http.response.start') {
                    $self->_add_cors_headers($event->{headers}, $origin);
                }
                await $send->($event);
            };
            await $app->($scope, $receive, $wrapped_send);
        } else {
            await $app->($scope, $receive, $send);
        }
    };
}

async sub _handle_preflight {
    my ($self, $scope, $send, $origin) = @_;

    my @headers;

    if ($self->_is_origin_allowed($origin)) {
        $self->_add_cors_headers(\@headers, $origin);

        # Add preflight-specific headers
        push @headers, ['Access-Control-Allow-Methods', join(', ', @{$self->{methods}})];
        push @headers, ['Access-Control-Allow-Headers', join(', ', @{$self->{headers}})];
        push @headers, ['Access-Control-Max-Age', $self->{max_age}];
    }

    await $send->({
        type    => 'http.response.start',
        status  => 204,
        headers => \@headers,
    });

    await $send->({
        type => 'http.response.body',
        body => '',
        more => 0,
    });
}

sub _add_cors_headers {
    my ($self, $headers, $origin) = @_;

    # Determine origin to return
    my $allowed_origin;
    if (grep { $_ eq '*' } @{$self->{origins}}) {
        $allowed_origin = $self->{credentials} ? $origin : '*';
    } else {
        $allowed_origin = $origin;
    }

    push @$headers, ['Access-Control-Allow-Origin', $allowed_origin];

    if ($self->{credentials}) {
        push @$headers, ['Access-Control-Allow-Credentials', 'true'];
    }

    if (@{$self->{expose_headers}}) {
        push @$headers, ['Access-Control-Expose-Headers', join(', ', @{$self->{expose_headers}})];
    }

    # Vary header for caching
    push @$headers, ['Vary', 'Origin'];
}

sub _is_origin_allowed {
    my ($self, $origin) = @_;

    return 1 if grep { $_ eq '*' } @{$self->{origins}};
    return 1 if grep { $_ eq $origin } @{$self->{origins}};
    return 0;
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

=head1 PREFLIGHT REQUESTS

When a browser sends a cross-origin request with certain characteristics
(custom headers, non-simple methods), it first sends an OPTIONS preflight
request. This middleware automatically responds to preflight requests
with the appropriate CORS headers.

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

=cut
