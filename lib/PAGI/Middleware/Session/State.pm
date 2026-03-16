package PAGI::Middleware::Session::State;

use strict;
use warnings;

=head1 NAME

PAGI::Middleware::Session::State - Base class for session state extraction

=head1 SYNOPSIS

    package My::State;
    use parent 'PAGI::Middleware::Session::State';

    sub extract {
        my ($self, $scope) = @_;
        # Return session ID or undef
    }

    sub inject {
        my ($self, $headers, $id, $options) = @_;
        # Push response header onto @$headers
    }

=head1 DESCRIPTION

PAGI::Middleware::Session::State defines the interface for session ID
transport. Subclasses determine how the session ID is extracted from
incoming requests and injected into outgoing responses.

=head1 METHODS

=head2 new

    my $state = PAGI::Middleware::Session::State->new(%options);

Create a new state handler.

=cut

sub new {
    my ($class, %options) = @_;

    return bless { %options }, $class;
}

=head2 extract

    my $session_id = $state->extract($scope);

Extract the session ID from the PAGI scope. Returns the session ID
string or undef if none is found. Subclasses must implement this.

=cut

sub extract {
    my ($self, $scope) = @_;

    die ref($self) . " must implement extract()";
}

=head2 inject

    $state->inject(\@headers, $id, \%options);

Inject the session ID into the response by pushing header arrayrefs
onto the provided headers array. Subclasses must implement this.

=cut

sub inject {
    my ($self, $headers, $id, $options) = @_;

    die ref($self) . " must implement inject()";
}

=head2 clear

    $state->clear(\@headers);

Clear the client-side session state (e.g., expire a cookie). Called
when a session is destroyed. The default implementation is a no-op,
suitable for state handlers where the client manages transport
(Header, Bearer). Cookie-based state handlers should override this
to emit an expired Set-Cookie header.

=cut

sub clear {
    my ($self, $headers) = @_;
    # Default: no-op (Header/Bearer don't need to clear anything)
}

1;

__END__

=head1 SEE ALSO

L<PAGI::Middleware::Session::State::Cookie> - Cookie-based session IDs

L<PAGI::Middleware::Session> - Session management middleware

=cut
