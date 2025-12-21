package PAGI::Middleware::ContentLength;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;

=head1 NAME

PAGI::Middleware::ContentLength - Auto Content-Length header middleware

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'ContentLength';
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::ContentLength automatically adds a Content-Length header
to responses that don't already have one. It buffers the response body
to calculate the length, then sends the complete response.

This middleware is useful when the application doesn't know the body
length upfront, but you want to avoid chunked encoding.

=head1 CONFIGURATION

=over 4

=item * auto_chunked (default: 0)

If true, skip adding Content-Length and let chunked encoding be used instead.
This is useful for large responses where buffering would be expensive.

=back

=cut

sub _init {
    my ($self, $config) = @_;

    $self->{auto_chunked} = $config->{auto_chunked} // 0;
}

sub wrap {
    my ($self, $app) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        # Skip for non-HTTP requests
        if ($scope->{type} ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        my @buffered_events;
        my $has_content_length = 0;
        my $is_streaming = 0;
        my $status;
        my @headers;

        # Create intercepting send to buffer response
        my $wrapped_send = async sub  {
        my ($event) = @_;
            my $type = $event->{type};

            if ($type eq 'http.response.start') {
                $status = $event->{status};
                @headers = @{$event->{headers} // []};

                # Check if Content-Length already present
                for my $h (@headers) {
                    if (lc($h->[0]) eq 'content-length') {
                        $has_content_length = 1;
                        last;
                    }
                    # If Transfer-Encoding is chunked, don't add Content-Length
                    if (lc($h->[0]) eq 'transfer-encoding' && lc($h->[1]) eq 'chunked') {
                        $is_streaming = 1;
                        last;
                    }
                }

                # If already has Content-Length or is streaming, pass through
                if ($has_content_length || $is_streaming || $self->{auto_chunked}) {
                    await $send->($event);
                    return;
                }

                # Buffer the start event to add Content-Length later
                push @buffered_events, $event;
            }
            elsif ($type eq 'http.response.body') {
                # If we're passing through (has Content-Length or streaming)
                if ($has_content_length || $is_streaming || $self->{auto_chunked}) {
                    await $send->($event);
                    return;
                }

                # Check if this is a streaming response (more => 1)
                if ($event->{more}) {
                    $is_streaming = 1;

                    # Flush buffered events and switch to pass-through
                    for my $buffered (@buffered_events) {
                        await $send->($buffered);
                    }
                    @buffered_events = ();
                    await $send->($event);
                    return;
                }

                # Buffer body events
                push @buffered_events, $event;
            }
            else {
                # Pass through other events (trailers, etc.)
                await $send->($event);
            }
        };

        # Run the inner app
        await $app->($scope, $receive, $wrapped_send);

        # If we have buffered events, calculate Content-Length and send
        if (@buffered_events && !$has_content_length && !$is_streaming) {
            # Calculate total body length
            my $body_length = 0;
            for my $event (@buffered_events) {
                if ($event->{type} eq 'http.response.body') {
                    $body_length += length($event->{body} // '');
                }
            }

            # Send start with Content-Length
            for my $event (@buffered_events) {
                if ($event->{type} eq 'http.response.start') {
                    push @{$event->{headers}}, ['content-length', $body_length];
                }
                await $send->($event);
            }
        }
    };
}

1;

__END__

=head1 NOTES

=over 4

=item * For streaming responses (multiple body events with more => 1),
this middleware switches to pass-through mode to avoid buffering.

=item * Responses that already have Content-Length are passed through unchanged.

=item * Responses with Transfer-Encoding: chunked are passed through unchanged.

=item * SSE and WebSocket responses should not use this middleware.

=back

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

=cut
