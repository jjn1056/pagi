package PAGI::Context::WebSocket;

use strict;
use warnings;

our @ISA = ('PAGI::Context');

=head1 NAME

PAGI::Context::WebSocket - WebSocket-specific context subclass

=head1 DESCRIPTION

Returned by C<< PAGI::Context->new(...) >> when C<< $scope->{type} >> is
C<'websocket'>. Adds a lazy accessor for L<PAGI::WebSocket>.

Inherits all shared methods from L<PAGI::Context>.

=head1 METHODS

=head2 websocket

    my $ws = $ctx->websocket;

Returns a L<PAGI::WebSocket> instance. Lazy-constructed and cached.

=head2 ws

    my $ws = $ctx->ws;

Alias for C<websocket>.

=cut

sub websocket {
    my ($self) = @_;
    return $self->{_websocket} //= do {
        require PAGI::WebSocket;
        PAGI::WebSocket->new($self->{scope}, $self->{receive}, $self->{send});
    };
}

sub ws { shift->websocket }

1;

__END__

=head1 SEE ALSO

L<PAGI::Context>, L<PAGI::WebSocket>

=cut
