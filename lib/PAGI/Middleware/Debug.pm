package PAGI::Middleware::Debug;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;
use Time::HiRes qw(time);
use JSON::MaybeXS ();

=head1 NAME

PAGI::Middleware::Debug - Development debug panel middleware

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'Debug',
            enabled => $ENV{PAGI_DEBUG};
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::Debug injects a debug panel into HTML responses
showing request/response details, timing breakdown, and headers.
Only enabled in development mode.

=head1 CONFIGURATION

=over 4

=item * enabled (default: 0)

Enable the debug panel. Should only be true in development.

=item * show_headers (default: 1)

Show request/response headers in debug panel.

=item * show_scope (default: 1)

Show scope contents in debug panel.

=item * show_timing (default: 1)

Show timing breakdown in debug panel.

=back

=cut

sub _init {
    my ($self, $config) = @_;

    $self->{enabled} = $config->{enabled} // 0;
    $self->{show_headers} = $config->{show_headers} // 1;
    $self->{show_scope} = $config->{show_scope} // 1;
    $self->{show_timing} = $config->{show_timing} // 1;
}

sub wrap {
    my ($self, $app) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        # Skip if not enabled or not HTTP
        if (!$self->{enabled} || $scope->{type} ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        my $start_time = time();
        my $response_status;
        my @response_headers;
        my $body = '';
        my $is_html = 0;
        my $headers_sent = 0;

        # Wrap send to capture response and inject panel
        my $wrapped_send = async sub  {
        my ($event) = @_;
            if ($event->{type} eq 'http.response.start') {
                $response_status = $event->{status};
                @response_headers = @{$event->{headers} // []};

                # Check if HTML response
                for my $h (@response_headers) {
                    if (lc($h->[0]) eq 'content-type' && $h->[1] =~ m{text/html}i) {
                        $is_html = 1;
                        last;
                    }
                }

                # If HTML, buffer; otherwise pass through
                if (!$is_html) {
                    $headers_sent = 1;
                    await $send->($event);
                }
                return;
            }

            if ($event->{type} eq 'http.response.body') {
                if ($is_html && !$headers_sent) {
                    # Buffer body
                    $body .= $event->{body} // '';

                    # If this is the final chunk, inject panel
                    if (!$event->{more}) {
                        my $panel = $self->_build_panel($scope, $start_time, $response_status, \@response_headers);

                        # Inject before </body> or at end
                        if ($body =~ s{(</body>)}{$panel$1}i) {
                            # Injected before </body>
                        } else {
                            $body .= $panel;
                        }

                        # Update Content-Length if present
                        for my $h (@response_headers) {
                            if (lc($h->[0]) eq 'content-length') {
                                $h->[1] = length($body);
                                last;
                            }
                        }

                        $headers_sent = 1;
                        await $send->({
                            type    => 'http.response.start',
                            status  => $response_status,
                            headers => \@response_headers,
                        });
                        await $send->({
                            type => 'http.response.body',
                            body => $body,
                            more => 0,
                        });
                    }
                } else {
                    await $send->($event);
                }
                return;
            }

            await $send->($event);
        };

        await $app->($scope, $receive, $wrapped_send);
    };
}

sub _build_panel {
    my ($self, $scope, $start_time, $status, $response_headers) = @_;

    my $duration = sprintf("%.3f", (time() - $start_time) * 1000);

    my $html = qq{
<style>
#pagi-debug-panel {
    position: fixed;
    bottom: 0;
    right: 0;
    width: 400px;
    max-height: 50vh;
    background: #1a1a2e;
    color: #eee;
    font-family: monospace;
    font-size: 12px;
    overflow: auto;
    border: 1px solid #333;
    border-radius: 8px 0 0 0;
    z-index: 99999;
    box-shadow: 0 0 10px rgba(0,0,0,0.5);
}
#pagi-debug-panel h3 {
    background: #16213e;
    margin: 0;
    padding: 8px 12px;
    cursor: pointer;
}
#pagi-debug-panel .content {
    padding: 10px;
}
#pagi-debug-panel table {
    width: 100%;
    border-collapse: collapse;
}
#pagi-debug-panel th, #pagi-debug-panel td {
    text-align: left;
    padding: 4px;
    border-bottom: 1px solid #333;
}
#pagi-debug-panel th { color: #0f4c75; }
#pagi-debug-panel .section { margin-bottom: 15px; }
#pagi-debug-panel .section-title { color: #3282b8; font-weight: bold; margin-bottom: 5px; }
</style>
<div id="pagi-debug-panel">
    <h3 onclick="this.parentElement.classList.toggle('collapsed')">PAGI Debug Panel</h3>
    <div class="content">
};

    # Timing section
    if ($self->{show_timing}) {
        $html .= qq{
        <div class="section">
            <div class="section-title">Timing</div>
            <table>
                <tr><th>Total Time</th><td>${duration}ms</td></tr>
                <tr><th>Status</th><td>$status</td></tr>
            </table>
        </div>
};
    }

    # Request section
    if ($self->{show_scope}) {
        my $method = _html_escape($scope->{method});
        my $path = _html_escape($scope->{path});
        my $query = _html_escape($scope->{query_string});
        my $scheme = _html_escape($scope->{scheme});
        $html .= qq{
        <div class="section">
            <div class="section-title">Request</div>
            <table>
                <tr><th>Method</th><td>$method</td></tr>
                <tr><th>Path</th><td>$path</td></tr>
                <tr><th>Query</th><td>$query</td></tr>
                <tr><th>Scheme</th><td>$scheme</td></tr>
            </table>
        </div>
};
    }

    # Request headers section
    if ($self->{show_headers} && $scope->{headers}) {
        $html .= qq{
        <div class="section">
            <div class="section-title">Request Headers</div>
            <table>
};
        for my $h (@{$scope->{headers}}) {
            my $name = _html_escape($h->[0]);
            my $value = _html_escape($h->[1]);
            $html .= qq{<tr><th>$name</th><td>$value</td></tr>\n};
        }
        $html .= qq{</table></div>};
    }

    # Response headers section
    if ($self->{show_headers}) {
        $html .= qq{
        <div class="section">
            <div class="section-title">Response Headers</div>
            <table>
};
        for my $h (@$response_headers) {
            my $name = _html_escape($h->[0]);
            my $value = _html_escape($h->[1]);
            $html .= qq{<tr><th>$name</th><td>$value</td></tr>\n};
        }
        $html .= qq{</table></div>};
    }

    $html .= qq{
    </div>
</div>
};

    return $html;
}

sub _html_escape {
    my $str = shift // '';
    $str =~ s/&/&amp;/g;
    $str =~ s/</&lt;/g;
    $str =~ s/>/&gt;/g;
    $str =~ s/"/&quot;/g;
    return $str;
}

1;

__END__

=head1 SECURITY WARNING

This middleware should NEVER be enabled in production. The debug panel
exposes sensitive information including headers, cookies, and internal
application details that could be exploited by attackers.

Always ensure C<enabled> is false in production environments.

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

L<PAGI::Middleware::Lint> - PAGI compliance validation

=cut
