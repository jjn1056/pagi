package PAGI::Middleware::WebSocket::RateLimit;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;
use Time::HiRes qw(time);

=head1 NAME

PAGI::Middleware::WebSocket::RateLimit - Rate limiting for WebSocket connections

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'WebSocket::RateLimit',
            messages_per_second => 10,
            bytes_per_second    => 65536,
            burst_multiplier    => 2;
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::WebSocket::RateLimit enforces rate limits on incoming
WebSocket messages. Connections exceeding limits can be throttled or
closed.

=head1 CONFIGURATION

=over 4

=item * messages_per_second (default: 100)

Maximum incoming messages per second.

=item * bytes_per_second (default: 1048576)

Maximum incoming bytes per second (1MB default).

=item * burst_multiplier (default: 2)

Allow bursts up to N times the limit before enforcing.

=item * on_limit_exceeded (optional)

Callback when limit exceeded. Receives ($scope, $type, $current, $limit).
Return true to close connection, false to just drop the message.

=item * close_code (default: 1008)

WebSocket close code when closing due to rate limit (Policy Violation).

=item * close_reason (default: 'Rate limit exceeded')

Close reason message.

=back

=cut

sub _init {
    my ($self, $config) = @_;

    $self->{messages_per_second} = $config->{messages_per_second} // 100;
    $self->{bytes_per_second} = $config->{bytes_per_second} // 1048576;
    $self->{burst_multiplier} = $config->{burst_multiplier} // 2;
    $self->{on_limit_exceeded} = $config->{on_limit_exceeded};
    $self->{close_code} = $config->{close_code} // 1008;
    $self->{close_reason} = $config->{close_reason} // 'Rate limit exceeded';
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

        my $msg_limit = $self->{messages_per_second};
        my $byte_limit = $self->{bytes_per_second};
        my $burst = $self->{burst_multiplier};

        # Token bucket state
        my $msg_tokens = $msg_limit * $burst;
        my $byte_tokens = $byte_limit * $burst;
        my $last_update = time();

        my $closed = 0;

        # Refill tokens based on elapsed time
        my $refill_tokens = sub {
            my $now = time();
            my $elapsed = $now - $last_update;
            $last_update = $now;

            $msg_tokens += $elapsed * $msg_limit;
            $msg_tokens = $msg_limit * $burst if $msg_tokens > $msg_limit * $burst;

            $byte_tokens += $elapsed * $byte_limit;
            $byte_tokens = $byte_limit * $burst if $byte_tokens > $byte_limit * $burst;
        };

        # Wrap receive to apply rate limiting
        my $wrapped_receive = async sub {
            return { type => 'websocket.disconnect' } if $closed;

            RECV: while (1) {
                my $event = await $receive->();

                return $event if $closed;
                return $event if $event->{type} ne 'websocket.receive';

                $refill_tokens->();

                # Calculate message size
                my $data = $event->{text} // $event->{bytes} // '';
                my $size = length($data);

                # Check message rate
                if ($msg_tokens < 1) {
                    my $should_close = $self->_handle_limit_exceeded(
                        $scope, $send, 'messages', 0, $msg_limit
                    );
                    if ($should_close) {
                        $closed = 1;
                        return { type => 'websocket.disconnect' };
                    }
                    # Drop message but continue
                    next RECV;
                }

                # Check byte rate
                if ($byte_tokens < $size) {
                    my $should_close = $self->_handle_limit_exceeded(
                        $scope, $send, 'bytes', $byte_tokens, $byte_limit
                    );
                    if ($should_close) {
                        $closed = 1;
                        return { type => 'websocket.disconnect' };
                    }
                    # Drop message but continue
                    next RECV;
                }

                # Consume tokens
                $msg_tokens -= 1;
                $byte_tokens -= $size;

                return $event;
            }
        };

        # Add rate limit info to scope
        my $new_scope = {
            %$scope,
            'pagi.websocket.rate_limit' => {
                messages_per_second => $msg_limit,
                bytes_per_second    => $byte_limit,
                burst_multiplier    => $burst,
            },
        };

        await $app->($new_scope, $wrapped_receive, $send);
    };
}

sub _handle_limit_exceeded {
    my ($self, $scope, $send, $type, $current, $limit) = @_;

    my $should_close = 1;  # Default to closing

    if ($self->{on_limit_exceeded}) {
        $should_close = $self->{on_limit_exceeded}->($scope, $type, $current, $limit);
    }

    if ($should_close) {
        # Send close frame
        $send->({
            type   => 'websocket.close',
            code   => $self->{close_code},
            reason => $self->{close_reason},
        })->retain;
    }

    return $should_close;
}

1;

__END__

=head1 ALGORITHM

This middleware uses a token bucket algorithm:

=over 4

=item * Each connection has message and byte token buckets

=item * Tokens refill at the configured rate

=item * Burst capacity allows temporary spikes

=item * When tokens depleted, messages are dropped or connection closed

=back

=head1 SCOPE EXTENSIONS

=over 4

=item * pagi.websocket.rate_limit

Hashref containing rate limit configuration.

=back

=head1 CALLBACK EXAMPLE

    enable 'WebSocket::RateLimit',
        messages_per_second => 10,
        on_limit_exceeded => sub  {
        my ($scope, $type, $current, $limit) = @_;
            warn "Rate limit exceeded for $scope->{client}[0]: $type\n";
            return 1;  # Close connection
        };

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

L<PAGI::Middleware::RateLimit> - HTTP rate limiting

L<PAGI::Middleware::WebSocket::Heartbeat> - WebSocket keepalive

=cut
