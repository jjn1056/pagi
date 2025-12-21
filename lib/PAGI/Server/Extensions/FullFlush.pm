package PAGI::Server::Extensions::FullFlush;
use strict;
use warnings;

our $VERSION = '0.001';

=head1 NAME

PAGI::Server::Extensions::FullFlush - Flush extension

=head1 SYNOPSIS

    use PAGI::Server::Extensions::FullFlush;

    my $ext = PAGI::Server::Extensions::FullFlush->new;
    await $ext->handle_event($connection, $event);

=head1 DESCRIPTION

PAGI::Server::Extensions::FullFlush handles the http.fullflush event,
forcing immediate flush of TCP write buffers.

=cut

sub new {
    my ($class, %args) = @_;

    return bless {}, $class;
}

sub handle_event {
    my ($self, $connection, $event) = @_;

    # TODO: Implement in Step 7
    # Force immediate flush of TCP buffer
}

1;

__END__

=head1 SEE ALSO

L<PAGI::Server>

=head1 AUTHOR

John Napiorkowski E<lt>jjnapiork@cpan.orgE<gt>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
