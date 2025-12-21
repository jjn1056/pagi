package PAGI::App::WebSocket::Echo;

use strict;
use warnings;
use Future::AsyncAwait;

=head1 NAME

PAGI::App::WebSocket::Echo - Echo WebSocket messages back to sender

=head1 SYNOPSIS

    use PAGI::App::WebSocket::Echo;

    my $app = PAGI::App::WebSocket::Echo->new->to_app;

=cut

sub new {
    my ($class, %args) = @_;

    return bless {
        on_connect    => $args{on_connect},
        on_disconnect => $args{on_disconnect},
    }, $class;
}

sub to_app {
    my ($self) = @_;

    my $on_connect = $self->{on_connect};
    my $on_disconnect = $self->{on_disconnect};

    return async sub  {
        my ($scope, $receive, $send) = @_;
        die "Unsupported scope type: $scope->{type}" if $scope->{type} ne 'websocket';

        # Accept the connection
        await $send->({ type => 'websocket.accept' });

        $on_connect->($scope) if $on_connect;

        # Echo loop
        while (1) {
            my $event = await $receive->();

            if ($event->{type} eq 'websocket.receive') {
                # Echo back - preserve text vs binary
                if (exists $event->{text}) {
                    await $send->({
                        type => 'websocket.send',
                        text => $event->{text},
                    });
                } elsif (exists $event->{bytes}) {
                    await $send->({
                        type => 'websocket.send',
                        bytes => $event->{bytes},
                    });
                }
            } elsif ($event->{type} eq 'websocket.disconnect') {
                $on_disconnect->($scope, $event->{code}) if $on_disconnect;
                last;
            }
        }
    };
}

1;

__END__

=head1 DESCRIPTION

Simple WebSocket echo server. Echoes all received messages back to
the sender, preserving message type (text or binary).

=head1 OPTIONS

=over 4

=item * C<on_connect> - Callback when client connects

=item * C<on_disconnect> - Callback when client disconnects

=back

=cut
