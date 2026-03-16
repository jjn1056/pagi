package PAGI::Middleware::Session::State::Header;

use strict;
use warnings;
use parent 'PAGI::Middleware::Session::State';

=head1 NAME

PAGI::Middleware::Session::State::Header - Header-based session ID transport

=head1 SYNOPSIS

    use PAGI::Middleware::Session::State::Header;

    my $state = PAGI::Middleware::Session::State::Header->new(
        header_name => 'X-Session-ID',
    );

    # With extraction pattern
    my $state = PAGI::Middleware::Session::State::Header->new(
        header_name => 'X-Auth-Token',
        pattern     => qr/^Token\s+(.+)$/i,
    );

    # Extract session ID from request
    my $id = $state->extract($scope);

=head1 DESCRIPTION

Implements the L<PAGI::Middleware::Session::State> interface using a custom
HTTP header for session ID transport. The session ID is read from the
specified request header. Injection is a no-op because the client is
responsible for managing header-based transport.

=head1 CONFIGURATION

=over 4

=item * header_name (required)

Name of the HTTP header containing the session ID.

=item * pattern (optional)

A regex with a capture group to extract the session ID from the header
value. If not provided, the full header value is used as the session ID.

=back

=cut

sub new {
    my ($class, %options) = @_;

    die "header_name is required for $class" unless defined $options{header_name};

    return $class->SUPER::new(%options);
}

=head2 extract

    my $session_id = $state->extract($scope);

Find the configured header in C<$scope-E<gt>{headers}> (case-insensitive)
and return its value as the session ID. If a C<pattern> is configured,
apply it and return the first capture group. Returns undef if the header
is not found or the pattern does not match.

=cut

sub extract {
    my ($self, $scope) = @_;

    my $value = $self->_get_header($scope, $self->{header_name});
    return unless defined $value;

    if (my $pattern = $self->{pattern}) {
        if ($value =~ $pattern) {
            return $1;
        }
        return;
    }

    return $value;
}

=head2 inject

    $state->inject(\@headers, $id, \%options);

No-op. Header-based session transport is managed by the client, so the
server does not inject any response headers.

=cut

sub inject {
    my ($self, $headers, $id, $options) = @_;

    # No-op: client manages header-based transport
    return;
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

=head1 SEE ALSO

L<PAGI::Middleware::Session::State> - Base state interface

L<PAGI::Middleware::Session::State::Bearer> - Bearer token shortcut

L<PAGI::Middleware::Session> - Session management middleware

=cut
