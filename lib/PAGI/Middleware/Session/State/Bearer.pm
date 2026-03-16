package PAGI::Middleware::Session::State::Bearer;

use strict;
use warnings;
use parent 'PAGI::Middleware::Session::State::Header';

=head1 NAME

PAGI::Middleware::Session::State::Bearer - Bearer token session ID transport

=head1 SYNOPSIS

    use PAGI::Middleware::Session::State::Bearer;

    my $state = PAGI::Middleware::Session::State::Bearer->new();

    # Extract session ID from Authorization: Bearer <token>
    my $id = $state->extract($scope);

=head1 DESCRIPTION

A convenience subclass of L<PAGI::Middleware::Session::State::Header> that
extracts an opaque bearer token from the C<Authorization> header. This is
intended for opaque session tokens, not JWTs.

Defaults to C<header_name =E<gt> 'Authorization'> and
C<pattern =E<gt> qr/^Bearer\s+(.+)$/i>. Both can be overridden via
constructor arguments.

=cut

sub new {
    my ($class, %args) = @_;

    $args{header_name} //= 'Authorization';
    $args{pattern}     //= qr/^Bearer\s+(.+)$/i;

    return $class->SUPER::new(%args);
}

1;

__END__

=head1 SEE ALSO

L<PAGI::Middleware::Session::State::Header> - General header-based transport

L<PAGI::Middleware::Session::State> - Base state interface

L<PAGI::Middleware::Session> - Session management middleware

=cut
