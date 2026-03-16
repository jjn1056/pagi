package PAGI::Middleware::Session::State::Callback;

use strict;
use warnings;
use parent 'PAGI::Middleware::Session::State';

=head1 NAME

PAGI::Middleware::Session::State::Callback - Custom coderef-based session ID transport

=head1 SYNOPSIS

    use PAGI::Middleware::Session::State::Callback;

    my $state = PAGI::Middleware::Session::State::Callback->new(
        extract => sub {
            my ($scope) = @_;
            # Return session ID or undef
            return $scope->{headers}[0][1];
        },
        inject => sub {
            my ($headers, $id, $options) = @_;
            push @$headers, ['X-Session-ID', $id];
        },
    );

    # Extract session ID from request
    my $id = $state->extract($scope);

=head1 DESCRIPTION

Implements the L<PAGI::Middleware::Session::State> interface using custom
coderefs for session ID extraction and injection. This allows callers to
define arbitrary session ID transport without writing a subclass.

=head1 CONFIGURATION

=over 4

=item * extract (required)

A coderef that receives C<($scope)> and returns the session ID or undef.

=item * inject (optional)

A coderef that receives C<(\@headers, $id, \%options)> and modifies the
response headers. Defaults to a no-op if not provided.

=item * clear (optional)

A coderef that receives C<(\@headers)> and clears the client-side
session state. Called when a session is destroyed. Defaults to a
no-op if not provided.

=back

=cut

sub new {
    my ($class, %options) = @_;

    die "extract is required for $class"
        unless defined $options{extract};
    die "extract must be a CODE ref for $class"
        unless ref($options{extract}) eq 'CODE';

    return $class->SUPER::new(%options);
}

=head2 extract

    my $session_id = $state->extract($scope);

Calls the configured C<extract> coderef with C<$scope> and returns
its result.

=cut

sub extract {
    my ($self, $scope) = @_;

    return $self->{extract}->($scope);
}

=head2 inject

    $state->inject(\@headers, $id, \%options);

Calls the configured C<inject> coderef with C<(\@headers, $id, \%options)>
if one was provided. Otherwise does nothing.

=cut

sub inject {
    my ($self, $headers, $id, $options) = @_;

    if ($self->{inject}) {
        $self->{inject}->($headers, $id, $options);
    }

    return;
}

=head2 clear

    $state->clear(\@headers);

Calls the configured C<clear> coderef with C<(\@headers)> if one was
provided. Otherwise does nothing.

=cut

sub clear {
    my ($self, $headers) = @_;

    if ($self->{clear}) {
        return $self->{clear}->($headers);
    }

    return;
}

1;

__END__

=head1 SEE ALSO

L<PAGI::Middleware::Session::State> - Base state interface

L<PAGI::Middleware::Session::State::Cookie> - Cookie-based session IDs

L<PAGI::Middleware::Session> - Session management middleware

=cut
