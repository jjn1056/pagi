package PAGI::Middleware::WebSocket::Heartbeat;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;
use Future;

=head1 NAME

PAGI::Middleware::WebSocket::Heartbeat - WebSocket keepalive via ping/pong

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'WebSocket::Heartbeat',
            interval => 30,
            timeout  => 10;
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::WebSocket::Heartbeat sends periodic ping frames to
WebSocket clients and monitors for pong responses. Connections that
don't respond within the timeout are closed.

=head1 CONFIGURATION

=over 4

=item * interval (default: 30)

Seconds between ping frames.

=item * timeout (default: 10)

Seconds to wait for pong response before considering connection dead.

=item * loop (optional)

IO::Async::Loop instance for scheduling.

=back

=cut

sub _init {
    my ($self, $config) = @_;

    $self->{interval} = $config->{interval} // 30;
    $self->{timeout} = $config->{timeout} // 10;
    $self->{loop} = $config->{loop};
}

sub wrap {
    my ($self, $app) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        # Only apply to WebSocket connections
        if ($scope->{type} ne 'websocket') {
            await $app->($scope, $receive, $send);
            return;
        }

        my $loop = $self->{loop} // $self->_get_loop();
        my $interval = $self->{interval};
        my $timeout = $self->{timeout};

        my $closed = 0;
        my $waiting_pong = 0;
        my $last_pong_time = time();
        my $ping_timer;
        my $timeout_timer;

        # Start ping timer after websocket.accept is sent
        my $start_pinging = sub {
            return if $closed;

            $ping_timer = $loop->delay_future(after => $interval)->on_done(sub {
                return if $closed;

                # Send ping
                $waiting_pong = 1;
                $send->({
                    type => 'websocket.send',
                    ping => 1,
                })->retain;

                # Start timeout timer
                $timeout_timer = $loop->delay_future(after => $timeout)->on_done(sub {
                    return if $closed || !$waiting_pong;

                    # No pong received, close connection
                    $closed = 1;
                    $send->({
                        type   => 'websocket.close',
                        code   => 1001,
                        reason => 'Heartbeat timeout',
                    })->retain;
                })->retain;

                # Schedule next ping
                __SUB__->();
            })->retain;
        };

        # Wrap send to detect accept and handle outgoing pings
        my $wrapped_send = async sub  {
        my ($event) = @_;
            return if $closed && $event->{type} ne 'websocket.close';

            if ($event->{type} eq 'websocket.accept') {
                await $send->($event);
                $start_pinging->();
                return;
            }

            if ($event->{type} eq 'websocket.close') {
                $closed = 1;
                $ping_timer->cancel if $ping_timer && !$ping_timer->is_ready;
                $timeout_timer->cancel if $timeout_timer && !$timeout_timer->is_ready;
            }

            await $send->($event);
        };

        # Wrap receive to detect pong and close events
        my $wrapped_receive = async sub {
            my $event = await $receive->();

            if ($event->{type} eq 'websocket.receive' && $event->{pong}) {
                # Pong received, reset timeout
                $waiting_pong = 0;
                $last_pong_time = time();
                $timeout_timer->cancel if $timeout_timer && !$timeout_timer->is_ready;
            } elsif ($event->{type} eq 'websocket.disconnect') {
                $closed = 1;
                $ping_timer->cancel if $ping_timer && !$ping_timer->is_ready;
                $timeout_timer->cancel if $timeout_timer && !$timeout_timer->is_ready;
            }

            return $event;
        };

        # Add heartbeat info to scope
        my $new_scope = {
            %$scope,
            'pagi.websocket.heartbeat' => {
                interval => $interval,
                timeout  => $timeout,
            },
        };

        eval {
            await $app->($new_scope, $wrapped_receive, $wrapped_send);
        };
        my $err = $@;

        # Cleanup timers
        $closed = 1;
        $ping_timer->cancel if $ping_timer && !$ping_timer->is_ready;
        $timeout_timer->cancel if $timeout_timer && !$timeout_timer->is_ready;

        die $err if $err;
    };
}

sub _get_loop {
    my ($self) = @_;

    require IO::Async::Loop;
    return IO::Async::Loop->new;
}

1;

__END__

=head1 HOW IT WORKS

After the application sends C<websocket.accept>, this middleware begins
sending ping frames at the configured interval. When a pong is received,
the timeout is reset. If no pong arrives within the timeout period,
the connection is closed with code 1001 (Going Away).

The middleware is transparent to the application - ping/pong frames
are handled automatically without passing through to the app.

=head1 SCOPE EXTENSIONS

=over 4

=item * pagi.websocket.heartbeat

Hashref containing C<interval> and C<timeout> settings.

=back

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

L<PAGI::Middleware::WebSocket::RateLimit> - Rate limiting for WebSocket

=cut
