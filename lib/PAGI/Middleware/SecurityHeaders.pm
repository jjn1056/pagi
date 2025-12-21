package PAGI::Middleware::SecurityHeaders;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;

=head1 NAME

PAGI::Middleware::SecurityHeaders - Security headers middleware

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'SecurityHeaders',
            x_frame_options         => 'DENY',
            x_content_type_options  => 'nosniff',
            x_xss_protection        => '1; mode=block',
            strict_transport_security => 'max-age=31536000; includeSubDomains';
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::SecurityHeaders adds common security-related HTTP headers
to responses. These headers help protect against various web vulnerabilities.

=head1 CONFIGURATION

=over 4

=item * x_frame_options (default: 'SAMEORIGIN')

Controls whether the page can be displayed in a frame.
Values: 'DENY', 'SAMEORIGIN', or 'ALLOW-FROM uri'.

=item * x_content_type_options (default: 'nosniff')

Prevents MIME type sniffing.

=item * x_xss_protection (default: '1; mode=block')

Enables XSS filter in browsers.

=item * referrer_policy (default: 'strict-origin-when-cross-origin')

Controls the Referer header.

=item * strict_transport_security (default: undef)

HSTS header. Set to enable HTTPS enforcement.

=item * content_security_policy (default: undef)

CSP header. Set to define content security policy.

=item * permissions_policy (default: undef)

Permissions-Policy header for feature control.

=back

=cut

sub _init {
    my ($self, $config) = @_;

    # Use exists() to allow explicitly passing undef to disable a header
    $self->{x_frame_options}            = exists $config->{x_frame_options}
        ? $config->{x_frame_options} : 'SAMEORIGIN';
    $self->{x_content_type_options}     = exists $config->{x_content_type_options}
        ? $config->{x_content_type_options} : 'nosniff';
    $self->{x_xss_protection}           = exists $config->{x_xss_protection}
        ? $config->{x_xss_protection} : '1; mode=block';
    $self->{referrer_policy}            = exists $config->{referrer_policy}
        ? $config->{referrer_policy} : 'strict-origin-when-cross-origin';
    $self->{strict_transport_security}  = $config->{strict_transport_security};
    $self->{content_security_policy}    = $config->{content_security_policy};
    $self->{permissions_policy}         = $config->{permissions_policy};
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

        # Intercept send to add security headers
        my $wrapped_send = async sub  {
        my ($event) = @_;
            if ($event->{type} eq 'http.response.start') {
                $self->_add_security_headers($event->{headers}, $scope);
            }
            await $send->($event);
        };

        await $app->($scope, $receive, $wrapped_send);
    };
}

sub _add_security_headers {
    my ($self, $headers, $scope) = @_;

    # X-Frame-Options
    if (defined $self->{x_frame_options}) {
        push @$headers, ['X-Frame-Options', $self->{x_frame_options}];
    }

    # X-Content-Type-Options
    if (defined $self->{x_content_type_options}) {
        push @$headers, ['X-Content-Type-Options', $self->{x_content_type_options}];
    }

    # X-XSS-Protection
    if (defined $self->{x_xss_protection}) {
        push @$headers, ['X-XSS-Protection', $self->{x_xss_protection}];
    }

    # Referrer-Policy
    if (defined $self->{referrer_policy}) {
        push @$headers, ['Referrer-Policy', $self->{referrer_policy}];
    }

    # Strict-Transport-Security (only for HTTPS)
    if (defined $self->{strict_transport_security}) {
        my $scheme = $scope->{scheme} // 'http';
        if ($scheme eq 'https') {
            push @$headers, ['Strict-Transport-Security', $self->{strict_transport_security}];
        }
    }

    # Content-Security-Policy
    if (defined $self->{content_security_policy}) {
        push @$headers, ['Content-Security-Policy', $self->{content_security_policy}];
    }

    # Permissions-Policy
    if (defined $self->{permissions_policy}) {
        push @$headers, ['Permissions-Policy', $self->{permissions_policy}];
    }
}

1;

__END__

=head1 SECURITY HEADERS

=head2 X-Frame-Options

Protects against clickjacking attacks by controlling whether the page
can be displayed in an iframe.

=head2 X-Content-Type-Options

Prevents browsers from MIME-sniffing responses, which can lead to
security vulnerabilities.

=head2 X-XSS-Protection

Enables the browser's XSS filter.

=head2 Referrer-Policy

Controls how much referrer information is sent with requests.

=head2 Strict-Transport-Security

Forces browsers to only use HTTPS for future requests to this domain.

=head2 Content-Security-Policy

Defines approved sources for content, helping prevent XSS and data injection.

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

=cut
