package PAGI::App::SSE::Stream;

use strict;
use warnings;
use Future::AsyncAwait;

=head1 NAME

PAGI::App::SSE::Stream - Server-Sent Events streaming

=head1 SYNOPSIS

    use PAGI::App::SSE::Stream;

    my $app = PAGI::App::SSE::Stream->new(
        generator => async sub ($send_event, $scope) {
            for my $i (1..10) {
                await $send_event->({ data => time() });
                await IO::Async::Loop->new->delay_future(after => 1);
            }
        },
    )->to_app;

=cut

sub new {
    my ($class, %args) = @_;

    return bless {
        generator   => $args{generator},
        retry       => $args{retry},
        on_connect  => $args{on_connect},
        on_close    => $args{on_close},
        headers     => $args{headers} // [],
    }, $class;
}

sub to_app {
    my ($self) = @_;

    my $generator = $self->{generator};
    my $retry = $self->{retry};
    my $on_connect = $self->{on_connect};
    my $on_close = $self->{on_close};
    my $extra_headers = $self->{headers};

    return async sub  {
        my ($scope, $receive, $send) = @_;
        die "Unsupported scope type: $scope->{type}" if $scope->{type} ne 'http';

        # Build headers
        my @headers = (
            ['content-type', 'text/event-stream'],
            ['cache-control', 'no-cache'],
            ['connection', 'keep-alive'],
            @$extra_headers,
        );

        # Start SSE response
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => \@headers,
        });

        # Send retry hint if configured
        if (defined $retry) {
            await $send->({
                type => 'http.response.body',
                body => "retry: $retry\n\n",
                more => 1,
            });
        }

        $on_connect->($scope) if $on_connect;

        # Track if client disconnected
        my $closed = 0;

        # Helper to send SSE events
        my $send_event = async sub  {
        my ($event) = @_;
            return if $closed;

            my $data = '';

            # Event type
            if ($event->{event}) {
                $data .= "event: $event->{event}\n";
            }

            # Event ID
            if ($event->{id}) {
                $data .= "id: $event->{id}\n";
            }

            # Data (handle multiline)
            my $content = $event->{data} // '';
            for my $line (split /\n/, $content) {
                $data .= "data: $line\n";
            }

            $data .= "\n";

            eval {
                await $send->({
                    type => 'http.response.body',
                    body => $data,
                    more => 1,
                });
            };
            if ($@) {
                $closed = 1;
            }
        };

        # Run generator
        if ($generator) {
            eval { await $generator->($send_event, $scope) };
        }

        # Cleanup
        $on_close->($scope) if $on_close;

        # End stream
        unless ($closed) {
            await $send->({
                type => 'http.response.body',
                body => '',
                more => 0,
            });
        }
    };
}

1;

__END__

=head1 DESCRIPTION

Server-Sent Events streaming application. Provides a generator-based
API for sending events to clients.

=head1 OPTIONS

=over 4

=item * C<generator> - Async coderef receiving ($send_event, $scope)

=item * C<retry> - Reconnection time in milliseconds

=item * C<on_connect> - Callback when client connects

=item * C<on_close> - Callback when stream ends

=item * C<headers> - Additional headers to send

=back

=head1 EVENT FORMAT

Events are hashrefs with optional keys:

=over 4

=item * C<data> - Event data (required for client to receive)

=item * C<event> - Event type name

=item * C<id> - Event ID for reconnection

=back

=cut
