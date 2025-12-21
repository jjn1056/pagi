package PAGI::Middleware::Lint;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;

=head1 NAME

PAGI::Middleware::Lint - Validate PAGI application compliance

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'Lint',
            strict => 1,
            on_warning => sub  {
        my ($msg) = @_; warn "PAGI Lint: $msg\n" };
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::Lint validates that wrapped applications follow the
PAGI specification. It checks for common mistakes and spec violations,
helping developers catch issues early.

=head1 CONFIGURATION

=over 4

=item * strict (default: 0)

In strict mode, violations throw exceptions instead of warnings.

=item * on_warning (optional)

Callback for lint warnings. Receives warning message.

=item * enabled (default: 1)

Set to false to completely disable lint checks.

=back

=cut

sub _init {
    my ($self, $config) = @_;

    $self->{strict} = $config->{strict} // 0;
    $self->{on_warning} = $config->{on_warning};
    $self->{enabled} = $config->{enabled} // 1;
}

sub wrap {
    my ($self, $app) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        if (!$self->{enabled}) {
            await $app->($scope, $receive, $send);
            return;
        }

        # Validate scope
        $self->_lint_scope($scope);

        my $response_started = 0;
        my $response_finished = 0;
        my $body_started = 0;
        my $event_count = 0;

        # Wrap send to validate outgoing events
        my $wrapped_send = async sub  {
        my ($event) = @_;
            $event_count++;

            $self->_lint_event($event, $scope->{type});

            if ($event->{type} eq 'http.response.start') {
                if ($response_started) {
                    $self->_warn("http.response.start sent multiple times");
                }
                $response_started = 1;
                $self->_lint_response_start($event);
            } elsif ($event->{type} eq 'http.response.body') {
                if (!$response_started) {
                    $self->_warn("http.response.body sent before http.response.start");
                }
                if ($response_finished) {
                    $self->_warn("http.response.body sent after response finished (more=0)");
                }
                $body_started = 1;
                if (!$event->{more}) {
                    $response_finished = 1;
                }
                $self->_lint_response_body($event);
            } elsif ($event->{type} eq 'websocket.accept') {
                if ($scope->{type} ne 'websocket') {
                    $self->_warn("websocket.accept sent for non-websocket scope");
                }
            } elsif ($event->{type} eq 'sse.start') {
                if ($scope->{type} ne 'sse') {
                    $self->_warn("sse.start sent for non-sse scope");
                }
            }

            await $send->($event);
        };

        eval {
            await $app->($scope, $receive, $wrapped_send);
        };
        my $err = $@;

        # Post-completion checks
        if ($scope->{type} eq 'http') {
            if (!$response_started) {
                $self->_warn("HTTP app completed without sending http.response.start");
            }
            if ($response_started && !$response_finished) {
                $self->_warn("HTTP app completed without sending final http.response.body (more=0)");
            }
        }

        die $err if $err;
    };
}

sub _lint_scope {
    my ($self, $scope) = @_;

    # Check required scope keys
    unless (defined $scope->{type}) {
        $self->_warn("scope missing required 'type' key");
    }

    if ($scope->{type} eq 'http') {
        my @required = qw(method path scheme);
        for my $key (@required) {
            unless (defined $scope->{$key}) {
                $self->_warn("HTTP scope missing required '$key' key");
            }
        }

        # Check headers format
        if (exists $scope->{headers}) {
            unless (ref $scope->{headers} eq 'ARRAY') {
                $self->_warn("scope headers must be arrayref, got " . ref($scope->{headers}));
            } else {
                for my $h (@{$scope->{headers}}) {
                    unless (ref $h eq 'ARRAY' && @$h == 2) {
                        $self->_warn("scope header must be [name, value] pair");
                    }
                    # Check lowercase header names
                    if ($h->[0] =~ /[A-Z]/) {
                        $self->_warn("header name should be lowercase: '$h->[0]'");
                    }
                }
            }
        }
    }
}

sub _lint_event {
    my ($self, $event, $scope_type) = @_;

    unless (ref $event eq 'HASH') {
        $self->_warn("event must be hashref, got " . ref($event));
        return;
    }

    unless (defined $event->{type}) {
        $self->_warn("event missing required 'type' key");
    }
}

sub _lint_response_start {
    my ($self, $event) = @_;

    unless (defined $event->{status}) {
        $self->_warn("http.response.start missing 'status' key");
    } elsif ($event->{status} !~ /^\d{3}$/) {
        $self->_warn("http.response.start status must be 3-digit code, got '$event->{status}'");
    }

    if (exists $event->{headers}) {
        unless (ref $event->{headers} eq 'ARRAY') {
            $self->_warn("response headers must be arrayref");
        } else {
            for my $h (@{$event->{headers}}) {
                unless (ref $h eq 'ARRAY' && @$h == 2) {
                    $self->_warn("response header must be [name, value] pair");
                }
            }
        }
    }
}

sub _lint_response_body {
    my ($self, $event) = @_;

    unless (defined $event->{more}) {
        $self->_warn("http.response.body should have 'more' key");
    }
}

sub _warn {
    my ($self, $msg) = @_;

    if ($self->{strict}) {
        die "PAGI Lint Error: $msg\n";
    }

    if ($self->{on_warning}) {
        $self->{on_warning}->($msg);
    } else {
        warn "PAGI Lint Warning: $msg\n";
    }
}

1;

__END__

=head1 CHECKS PERFORMED

=head2 Scope Validation

=over 4

=item * Required C<type> key present

=item * HTTP scope has C<method>, C<path>, C<scheme>

=item * Headers are arrayref of [name, value] pairs

=item * Header names are lowercase

=back

=head2 Event Validation

=over 4

=item * Events are hashrefs with C<type> key

=item * C<http.response.start> has C<status>

=item * C<http.response.body> has C<more> key

=item * Events sent in correct order

=item * No events after response finished

=back

=head2 Completion Validation

=over 4

=item * HTTP apps send C<http.response.start>

=item * HTTP apps send final C<http.response.body> with C<more=0>

=back

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

L<PAGI::Middleware::Debug> - Development debug panel

=cut
