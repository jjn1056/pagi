package PAGI::Context::HTTP;

use strict;
use warnings;

our @ISA = ('PAGI::Context');

=head1 NAME

PAGI::Context::HTTP - HTTP-specific context subclass

=head1 DESCRIPTION

Returned by C<< PAGI::Context->new(...) >> when C<< $scope->{type} >> is
C<'http'>. Adds lazy accessors for L<PAGI::Request> and L<PAGI::Response>,
plus an HTTP C<method> accessor.

Inherits all shared methods from L<PAGI::Context>.

=head1 METHODS

=head2 request

    my $req = $ctx->request;

Returns a L<PAGI::Request> instance. Lazy-constructed and cached.

=head2 response

    my $res = $ctx->response;

Returns a L<PAGI::Response> instance. Lazy-constructed and cached.

=head2 method

    my $method = $ctx->method;    # 'GET', 'POST', etc.

Returns the HTTP method from the scope.

=head2 req

    my $req = $ctx->req;

Alias for C<request>.

=head2 resp

    my $res = $ctx->resp;

Alias for C<response>.

=cut

sub request {
    my ($self) = @_;
    return $self->{_request} //= do {
        require PAGI::Request;
        PAGI::Request->new($self->{scope}, $self->{receive});
    };
}

sub response {
    my ($self) = @_;
    return $self->{_response} //= do {
        require PAGI::Response;
        PAGI::Response->new($self->{scope}, $self->{send});
    };
}

sub method { shift->{scope}{method} }

sub req  { shift->request }
sub resp { shift->response }

1;

__END__

=head1 SEE ALSO

L<PAGI::Context>, L<PAGI::Request>, L<PAGI::Response>

=cut
