package PAGI::Middleware::SSE::Retry;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;

=head1 NAME

PAGI::Middleware::SSE::Retry - Add retry hints to SSE events

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'SSE::Retry',
            retry => 5000;  # 5 seconds
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::SSE::Retry adds the C<retry> field to SSE events,
telling clients how long to wait before reconnecting after a disconnect.

=head1 CONFIGURATION

=over 4

=item * retry (default: 3000)

Default retry interval in milliseconds.

=item * include_on_start (default: 1)

If true, sends a retry hint immediately after sse.start.

=item * include_on_events (default: 0)

If true, includes retry in every sse.send event.

=back

=cut

sub _init {
    my ($self, $config) = @_;

    $self->{retry} = $config->{retry} // 3000;
    $self->{include_on_start} = $config->{include_on_start} // 1;
    $self->{include_on_events} = $config->{include_on_events} // 0;
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

        my $retry = $self->{retry};
        my $sent_initial = 0;

        # Wrap send to add retry field
        my $wrapped_send = async sub  {
        my ($event) = @_;
            if ($event->{type} eq 'sse.start') {
                await $send->($event);

                # Send initial retry hint
                if ($self->{include_on_start} && !$sent_initial) {
                    $sent_initial = 1;
                    await $send->({
                        type  => 'sse.send',
                        retry => $retry,
                    });
                }
                return;
            }

            if ($event->{type} eq 'sse.send') {
                # Add retry to event if configured and not already present
                if ($self->{include_on_events} && !defined $event->{retry}) {
                    $event = { %$event, retry => $retry };
                }
            }

            await $send->($event);
        };

        # Add retry info to scope
        my $new_scope = {
            %$scope,
            'pagi.sse.retry' => $retry,
        };

        await $app->($new_scope, $receive, $wrapped_send);
    };
}

1;

__END__

=head1 HOW IT WORKS

The middleware intercepts outgoing SSE events and adds the C<retry> field.
By default, a retry hint is sent immediately after C<sse.start> to inform
clients of the reconnection interval before any data events.

The retry value is in milliseconds and tells the browser's EventSource API
how long to wait before attempting to reconnect after a disconnect.

=head1 SCOPE EXTENSIONS

=over 4

=item * pagi.sse.retry

The configured retry interval in milliseconds.

=back

=head1 LAST-EVENT-ID

This middleware does not handle the Last-Event-ID header for resumption.
Applications should check C<$scope-E<gt>{headers}> for the Last-Event-ID
header and resume from the appropriate point in the event stream.

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

L<PAGI::Middleware::SSE::Heartbeat> - SSE keepalive comments

=cut
