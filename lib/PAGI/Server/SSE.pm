package PAGI::Server::SSE;
use strict;
use warnings;

our $VERSION = '0.001';

=head1 NAME

PAGI::Server::SSE - Server-Sent Events handler

=head1 SYNOPSIS

    use PAGI::Server::SSE;

    my $sse = PAGI::Server::SSE->new(connection => $conn);
    $sse->handle_request($scope);

=head1 DESCRIPTION

PAGI::Server::SSE handles Server-Sent Events connections, formatting
events according to the SSE wire protocol.

=cut

sub new {
    my ($class, %args) = @_;

    my $self = bless {
        connection => $args{connection},
    }, $class;
    return $self;
}

sub handle_start {
    my ($self, $event) = @_;

    # TODO: Implement in Step 5
}

sub handle_send {
    my ($self, $event) = @_;

    # TODO: Implement in Step 5
}

sub format_event {
    my ($self, $event) = @_;

    # TODO: Implement in Step 5
    # Format: event: name\ndata: line1\ndata: line2\n\n
    return '';
}

1;

__END__

=head1 SEE ALSO

L<PAGI::Server::Connection>

=head1 AUTHOR

John Napiorkowski E<lt>jjnapiork@cpan.orgE<gt>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
