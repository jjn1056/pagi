package PAGI::Middleware::SSE::Heartbeat;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;
use Future;

=head1 NAME

PAGI::Middleware::SSE::Heartbeat - SSE keepalive via comment lines

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'SSE::Heartbeat',
            interval => 15;
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::SSE::Heartbeat sends periodic comment lines (C<: keepalive>)
to SSE connections to prevent proxy timeouts and keep connections alive.

=head1 CONFIGURATION

=over 4

=item * interval (default: 15)

Seconds between heartbeat comments.

=item * comment (default: 'keepalive')

The comment text to send. Will be prefixed with ': '.

=item * loop (optional)

IO::Async::Loop instance for scheduling.

=back

=cut

sub _init {
    my ($self, $config) = @_;

    $self->{interval} = $config->{interval} // 15;
    $self->{comment} = $config->{comment} // 'keepalive';
    $self->{loop} = $config->{loop};
}

sub wrap {
    my ($self, $app) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        # Only apply to SSE connections
        if ($scope->{type} ne 'sse') {
            await $app->($scope, $receive, $send);
            return;
        }

        my $loop = $self->{loop} // $self->_get_loop();
        my $interval = $self->{interval};
        my $comment = $self->{comment};

        my $closed = 0;
        my $heartbeat_timer;

        # Start heartbeat timer after sse.start
        my $start_heartbeat = sub {
            return if $closed;

            $heartbeat_timer = $loop->delay_future(after => $interval)->on_done(sub {
                return if $closed;

                # Send comment as heartbeat
                $send->({
                    type    => 'sse.send',
                    comment => $comment,
                })->retain;

                # Schedule next heartbeat
                __SUB__->();
            })->retain;
        };

        # Wrap send to start heartbeat after sse.start
        my $wrapped_send = async sub  {
        my ($event) = @_;
            if ($event->{type} eq 'sse.start') {
                await $send->($event);
                $start_heartbeat->();
                return;
            }

            if ($event->{type} eq 'sse.close') {
                $closed = 1;
                $heartbeat_timer->cancel if $heartbeat_timer && !$heartbeat_timer->is_ready;
            }

            await $send->($event);
        };

        # Wrap receive to detect disconnect
        my $wrapped_receive = async sub {
            my $event = await $receive->();

            if ($event->{type} eq 'sse.disconnect') {
                $closed = 1;
                $heartbeat_timer->cancel if $heartbeat_timer && !$heartbeat_timer->is_ready;
            }

            return $event;
        };

        # Add heartbeat info to scope
        my $new_scope = {
            %$scope,
            'pagi.sse.heartbeat' => {
                interval => $interval,
                comment  => $comment,
            },
        };

        eval {
            await $app->($new_scope, $wrapped_receive, $wrapped_send);
        };
        my $err = $@;

        # Cleanup timer
        $closed = 1;
        $heartbeat_timer->cancel if $heartbeat_timer && !$heartbeat_timer->is_ready;

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

After the application sends C<sse.start>, this middleware begins sending
comment lines at the configured interval. SSE comments (lines starting
with ':') are ignored by the browser's EventSource API but keep the
TCP connection alive through proxies.

The middleware is mostly transparent to the application - heartbeat
comments are sent automatically without any action needed from the app.

=head1 WHY HEARTBEATS

Many HTTP proxies, load balancers, and firewalls close idle connections
after a timeout (commonly 30-60 seconds). For long-lived SSE streams
where events may be infrequent, heartbeat comments prevent these
premature disconnections.

=head1 SCOPE EXTENSIONS

=over 4

=item * pagi.sse.heartbeat

Hashref containing C<interval> and C<comment> settings.

=back

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

L<PAGI::Middleware::SSE::Retry> - SSE retry hints

=cut
