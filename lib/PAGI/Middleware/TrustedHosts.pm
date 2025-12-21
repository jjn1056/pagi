package PAGI::Middleware::TrustedHosts;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;

=head1 NAME

PAGI::Middleware::TrustedHosts - Host header validation middleware

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'TrustedHosts',
            hosts => ['example.com', 'www.example.com', '*.example.com'];
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::TrustedHosts validates the Host header against a list
of allowed hosts. This helps prevent host header injection attacks.

=head1 CONFIGURATION

=over 4

=item * hosts (required)

Array of allowed host patterns. Patterns can include:
- Exact hostnames: 'example.com'
- Wildcard subdomains: '*.example.com'
- Port specifications: 'example.com:8080'

=item * allow_empty (default: 0)

If true, allow requests without a Host header.

=back

=cut

sub _init {
    my ($self, $config) = @_;

    $self->{hosts}       = $config->{hosts} // die "TrustedHosts requires 'hosts' option";
    $self->{allow_empty} = $config->{allow_empty} // 0;

    # Compile host patterns to regexes
    $self->{_patterns} = [map { $self->_compile_pattern($_) } @{$self->{hosts}}];
}

sub _compile_pattern {
    my ($self, $pattern) = @_;

    # Escape regex special chars except *
    my $escaped = quotemeta($pattern);
    # Convert escaped * back to regex wildcard
    $escaped =~ s/\\\*/.*/g;
    return qr/^$escaped$/i;
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

        # Get Host header
        my $host = $self->_get_header($scope, 'host');

        # Check if host is allowed
        if (!defined $host || $host eq '') {
            if ($self->{allow_empty}) {
                await $app->($scope, $receive, $send);
                return;
            }
            await $self->_send_error($send, 400, 'Missing Host header');
            return;
        }

        # Strip port for matching if needed
        my $host_for_match = $host;

        # Check against patterns
        my $allowed = 0;
        for my $pattern (@{$self->{_patterns}}) {
            if ($host_for_match =~ $pattern) {
                $allowed = 1;
                last;
            }
        }

        if ($allowed) {
            await $app->($scope, $receive, $send);
        } else {
            await $self->_send_error($send, 400, 'Invalid Host header');
        }
    };
}

sub _get_header {
    my ($self, $scope, $name) = @_;

    $name = lc($name);
    for my $h (@{$scope->{headers} // []}) {
        return $h->[1] if lc($h->[0]) eq $name;
    }
    return;
}

async sub _send_error {
    my ($self, $send, $status, $message) = @_;

    await $send->({
        type    => 'http.response.start',
        status  => $status,
        headers => [
            ['content-type', 'text/plain'],
            ['content-length', length($message)],
        ],
    });
    await $send->({
        type => 'http.response.body',
        body => $message,
        more => 0,
    });
}

1;

__END__

=head1 HOST HEADER ATTACKS

Host header injection attacks can lead to:

=over 4

=item * Cache poisoning

=item * Password reset poisoning

=item * Server-Side Request Forgery (SSRF)

=item * SQL injection in some cases

=back

This middleware prevents these attacks by validating the Host header
against a whitelist of allowed hosts.

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

=cut
