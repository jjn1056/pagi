package PAGI::Middleware::ErrorHandler;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;
use Scalar::Util 'blessed';

=head1 NAME

PAGI::Middleware::ErrorHandler - Exception handling middleware

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'ErrorHandler',
            development => 1,
            on_error    => sub  {
        my ($error) = @_; warn "App error: $error" };
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::ErrorHandler catches exceptions thrown by the inner
application and converts them to appropriate HTTP error responses.

=head1 CONFIGURATION

=over 4

=item * development (default: 0)

If true, include stack trace in error responses. Should be false in production.

=item * on_error (default: undef)

Callback invoked with the error when an exception is caught. Useful for logging.

    on_error => sub  {
        my ($error) = @_; $logger->error($error) }

=item * content_type (default: 'text/html')

Content type for error responses. Supported: 'text/html', 'application/json', 'text/plain'

=item * status (default: 500)

HTTP status code for general exceptions.

=back

=cut

sub _init {
    my ($self, $config) = @_;

    $self->{development} = $config->{development} // 0;
    $self->{on_error}    = $config->{on_error};
    $self->{content_type} = $config->{content_type} // 'text/html';
    $self->{status}      = $config->{status} // 500;
}

sub wrap {
    my ($self, $app) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        # Only handle HTTP requests
        if ($scope->{type} ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        my $response_started = 0;

        # Intercept send to track if response has started
        my $wrapped_send = async sub  {
        my ($event) = @_;
            if ($event->{type} eq 'http.response.start') {
                $response_started = 1;
            }
            await $send->($event);
        };

        # Try to run the app
        my $error;
        eval {
            await $app->($scope, $receive, $wrapped_send);
            1;
        } or do {
            $error = $@ || 'Unknown error';
        };

        # Handle error if one occurred
        if ($error) {
            # Call on_error callback if provided
            if ($self->{on_error}) {
                eval { $self->{on_error}->($error) };
            }

            # If response already started, we can't send error page
            if ($response_started) {
                # Best we can do is log and close
                warn "Error occurred after response started: $error\n";
                return;
            }

            # Determine status code
            my $status = $self->{status};

            # Check for specific exception types
            if (blessed($error) && $error->can('status_code')) {
                $status = $error->status_code;
            }

            # Generate error response
            my ($body, $content_type) = $self->_generate_error_body($error, $status);

            await $send->({
                type    => 'http.response.start',
                status  => $status,
                headers => [
                    ['content-type', $content_type],
                    ['content-length', length($body)],
                ],
            });

            await $send->({
                type => 'http.response.body',
                body => $body,
                more => 0,
            });
        }
    };
}

sub _generate_error_body {
    my ($self, $error, $status) = @_;

    my $error_text = "$error";
    my $content_type = $self->{content_type};

    # Clean up error for display
    my $display_error = $error_text;
    unless ($self->{development}) {
        # In production, don't reveal internal details
        $display_error = $self->_status_message($status);
    }

    if ($content_type eq 'application/json') {
        require JSON::PP;
        my $body = JSON::PP::encode_json({
            error  => $display_error,
            status => $status,
            ($self->{development} ? (stack => $error_text) : ()),
        });
        return ($body, 'application/json');
    }
    elsif ($content_type eq 'text/plain') {
        my $body = "Error $status: $display_error";
        if ($self->{development} && $error_text ne $display_error) {
            $body .= "\n\nStack trace:\n$error_text";
        }
        return ($body, 'text/plain; charset=utf-8');
    }
    else {
        # Default to HTML
        my $safe_error = $self->_html_escape($display_error);
        my $safe_stack = $self->{development} ? $self->_html_escape($error_text) : '';

        my $body = <<"HTML";
<!DOCTYPE html>
<html>
<head>
    <title>Error $status</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 40px; }
        h1 { color: #c00; }
        .error { background: #fee; padding: 20px; border-radius: 4px; margin: 20px 0; }
        pre { background: #f4f4f4; padding: 15px; overflow-x: auto; border-radius: 4px; }
    </style>
</head>
<body>
    <h1>Error $status</h1>
    <div class="error">$safe_error</div>
HTML

        if ($self->{development} && $safe_stack) {
            $body .= "    <h2>Stack Trace</h2>\n    <pre>$safe_stack</pre>\n";
        }

        $body .= "</body>\n</html>\n";

        return ($body, 'text/html; charset=utf-8');
    }
}

sub _html_escape {
    my ($self, $text) = @_;

    $text =~ s/&/&amp;/g;
    $text =~ s/</&lt;/g;
    $text =~ s/>/&gt;/g;
    $text =~ s/"/&quot;/g;
    return $text;
}

sub _status_message {
    my ($self, $status) = @_;

    my %messages = (
        400 => 'Bad Request',
        401 => 'Unauthorized',
        403 => 'Forbidden',
        404 => 'Not Found',
        405 => 'Method Not Allowed',
        408 => 'Request Timeout',
        413 => 'Payload Too Large',
        429 => 'Too Many Requests',
        500 => 'Internal Server Error',
        502 => 'Bad Gateway',
        503 => 'Service Unavailable',
        504 => 'Gateway Timeout',
    );
    return $messages{$status} // 'Error';
}

1;

__END__

=head1 EXCEPTION HANDLING

The middleware supports exception objects with a C<status_code> method
to set custom HTTP status codes:

    package My::Exception;
    sub new { bless { status => $_[1], message => $_[2] }, $_[0] }
    sub status_code { $_[0]->{status} }

    # In app:
    die My::Exception->new(404, 'Resource not found');

=head1 NOTES

=over 4

=item * If the response has already started when an error occurs,
the middleware cannot send an error page. It will log the error and return.

=item * In development mode, the full error message and stack trace are
included in the response. In production, only a generic message is shown.

=item * For non-HTTP requests (WebSocket, SSE), errors are propagated
without transformation.

=back

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

=cut
