package PAGI::WebSocket;
use strict;
use warnings;
use Carp qw(croak);
use Hash::MultiValue;

our $VERSION = '0.01';

sub new {
    my ($class, $scope, $receive, $send) = @_;

    croak "PAGI::WebSocket requires scope hashref"
        unless $scope && ref($scope) eq 'HASH';
    croak "PAGI::WebSocket requires receive coderef"
        unless $receive && ref($receive) eq 'CODE';
    croak "PAGI::WebSocket requires send coderef"
        unless $send && ref($send) eq 'CODE';
    croak "PAGI::WebSocket requires scope type 'websocket', got '$scope->{type}'"
        unless ($scope->{type} // '') eq 'websocket';

    return bless {
        scope   => $scope,
        receive => $receive,
        send    => $send,
        _state  => 'connecting',  # connecting -> connected -> closed
        _close_code   => undef,
        _close_reason => undef,
        _on_close     => [],
    }, $class;
}

# Scope property accessors
sub scope        { shift->{scope} }
sub path         { shift->{scope}{path} }
sub raw_path     { my $s = shift; $s->{scope}{raw_path} // $s->{scope}{path} }
sub query_string { shift->{scope}{query_string} // '' }
sub scheme       { shift->{scope}{scheme} // 'ws' }
sub http_version { shift->{scope}{http_version} // '1.1' }
sub subprotocols { shift->{scope}{subprotocols} // [] }
sub client       { shift->{scope}{client} }
sub server       { shift->{scope}{server} }

# Single header lookup (case-insensitive, returns last value)
sub header {
    my ($self, $name) = @_;
    $name = lc($name);
    my $value;
    for my $pair (@{$self->{scope}{headers} // []}) {
        if (lc($pair->[0]) eq $name) {
            $value = $pair->[1];
        }
    }
    return $value;
}

# All headers as Hash::MultiValue (cached)
sub headers {
    my $self = shift;
    return $self->{_headers} if $self->{_headers};

    my @pairs;
    for my $pair (@{$self->{scope}{headers} // []}) {
        push @pairs, lc($pair->[0]), $pair->[1];
    }

    $self->{_headers} = Hash::MultiValue->new(@pairs);
    return $self->{_headers};
}

# All values for a header
sub header_all {
    my ($self, $name) = @_;
    return $self->headers->get_all(lc($name));
}

1;

__END__

=head1 NAME

PAGI::WebSocket - Convenience wrapper for PAGI WebSocket connections

=head1 SYNOPSIS

    use PAGI::WebSocket;
    use Future::AsyncAwait;

    async sub app {
        my ($scope, $receive, $send) = @_;

        my $ws = PAGI::WebSocket->new($scope, $receive, $send);
        await $ws->accept;

        while (my $msg = await $ws->receive_text) {
            await $ws->send_text("Echo: $msg");
        }
    }

=head1 CONSTRUCTOR

=head2 new

    my $ws = PAGI::WebSocket->new($scope, $receive, $send);

Creates a new WebSocket wrapper. All parameters are required:

=over 4

=item * C<$scope> - PAGI scope hashref with type 'websocket'

=item * C<$receive> - Async coderef for receiving messages from client

=item * C<$send> - Async coderef for sending messages to client

=back

Throws an exception if parameters are missing or if scope type is not 'websocket'.

=head1 DESCRIPTION

PAGI::WebSocket provides a clean, high-level API for WebSocket handling,
inspired by Starlette's WebSocket class. It wraps the raw PAGI protocol
and provides:

=over 4

=item * Typed send/receive methods (text, bytes, JSON)

=item * Connection state tracking

=item * Cleanup callback registration

=item * Safe send methods for broadcast scenarios

=item * Message iteration helpers

=back

=cut
