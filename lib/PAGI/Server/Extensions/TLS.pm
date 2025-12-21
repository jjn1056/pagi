package PAGI::Server::Extensions::TLS;
use strict;
use warnings;

our $VERSION = '0.001';

=head1 NAME

PAGI::Server::Extensions::TLS - TLS extension

=head1 SYNOPSIS

    use PAGI::Server::Extensions::TLS;

    my $tls_ext = PAGI::Server::Extensions::TLS->new;
    my $info = $tls_ext->extract_info($ssl_socket);

=head1 DESCRIPTION

PAGI::Server::Extensions::TLS extracts TLS connection information
and populates the scope->{extensions}{tls} hashref.

=cut

sub new {
    my ($class, %args) = @_;

    return bless {}, $class;
}

sub extract_info {
    my ($self, $socket) = @_;

    # TODO: Implement in Step 8
    # Returns hashref with:
    #   server_cert, client_cert_chain, client_cert_name,
    #   client_cert_error, tls_version, cipher_suite
    return;
}

1;

__END__

=head1 SEE ALSO

L<PAGI::Server>, L<IO::Async::SSL>

=head1 AUTHOR

John Napiorkowski E<lt>jjnapiork@cpan.orgE<gt>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
