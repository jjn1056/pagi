package PAGI::Middleware;

use strict;
use warnings;
use Future::AsyncAwait;

=head1 NAME

PAGI::Middleware - Base class for PAGI middleware

=head1 SYNOPSIS

    # Create a custom middleware
    package My::Middleware;
    use parent 'PAGI::Middleware';

    sub wrap {
        my ($self, $app) = @_;
    
        return async sub  {
        my ($scope, $receive, $send) = @_;
            # Modify scope for inner app
            my $modified_scope = $self->modify_scope($scope, {
                custom_key => 'custom_value',
            });

            # Call inner app with modified scope
            await $app->($modified_scope, $receive, $send);
        };
    }

    # Use the builder DSL
    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'My::Middleware', option => 'value';
        enable_if { $_[0]->{path} =~ m{^/api/} } 'RateLimit', limit => 100;
        mount '/static' => $static_app;
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware provides a base class for implementing middleware that wraps
PAGI applications. Middleware can modify the request scope, intercept responses,
or perform cross-cutting concerns like logging, authentication, or compression.

=head1 METHODS

=head2 new

    my $middleware = PAGI::Middleware->new(%config);

Create a new middleware instance. Configuration options are stored and
accessible via C<$self-E<gt>{config}>.

=cut

sub new {
    my ($class, %config) = @_;

    my $self = bless {
        config => \%config,
    }, $class;
    $self->_init(\%config);
    return $self;
}

=head2 _init

    $self->_init(\%config);

Hook for subclasses to perform initialization. Called by new().
Default implementation does nothing.

=cut

sub _init {
    my ($self, $config) = @_;

    # Subclasses can override
}

=head2 wrap

    my $wrapped_app = $middleware->wrap($app);

Wrap a PAGI application. Returns a new async sub that handles
the middleware logic. Subclasses MUST override this method.

=cut

sub wrap {
    my ($self, $app) = @_;

    die "Subclass must implement wrap()";
}

=head2 modify_scope

    my $new_scope = $self->modify_scope($scope, \%additions);

Create a new scope with additional keys, without mutating the original.
This is the recommended way to pass additional data to inner apps.

=cut

sub modify_scope {
    my ($self, $scope, $additions) = @_;
    $additions //= {};

    return { %$scope, %$additions };
}

=head2 intercept_send

    my $wrapped_send = $self->intercept_send($send, \&interceptor);

Wrap the $send callback to intercept outgoing events.
The interceptor is called with ($event, $original_send) and should
return a Future.

    my $wrapped_send = $self->intercept_send($send, async sub  {
        my ($event, $original_send) = @_;
        if ($event->{type} eq 'http.response.start') {
            # Modify headers
            push @{$event->{headers}}, ['x-custom', 'value'];
        }
        await $original_send->($event);
    });

=cut

sub intercept_send {
    my ($self, $send, $interceptor) = @_;

    return async sub  {
        my ($event) = @_;
        await $interceptor->($event, $send);
    };
}

=head2 buffer_request_body

    my ($body, $final_event) = await $self->buffer_request_body($receive);

Collect all request body chunks into a single string.
Returns the complete body and the final http.request event.

=cut

async sub buffer_request_body {
    my ($self, $receive) = @_;

    my $body = '';
    my $event;

    while (1) {
        $event = await $receive->();

        if ($event->{type} eq 'http.request') {
            $body .= $event->{body} // '';
            last unless $event->{more};
        } elsif ($event->{type} eq 'http.disconnect') {
            last;
        }
    }

    return ($body, $event);
}

=head2 call

    await $middleware->call($scope, $receive, $send, $app);

Convenience method to invoke the middleware with an app.
Equivalent to:

    my $wrapped = $middleware->wrap($app);
    await $wrapped->($scope, $receive, $send);

=cut

async sub call {
    my ($self, $scope, $receive, $send, $app) = @_;

    my $wrapped = $self->wrap($app);
    await $wrapped->($scope, $receive, $send);
}

1;

__END__

=head1 WRITING MIDDLEWARE

Middleware follows the decorator pattern. Each middleware wraps an inner
application and can:

=over 4

=item * Modify the scope before passing to the inner app

=item * Intercept and modify the $send callback

=item * Short-circuit the request (return early without calling inner app)

=item * Perform actions before and after the inner app runs

=back

=head2 Example: Logging Middleware

    package PAGI::Middleware::Logger;
    use parent 'PAGI::Middleware';
    use Future::AsyncAwait;
    use Time::HiRes 'time';

    sub wrap {
        my ($self, $app) = @_;
    
        return async sub  {
        my ($scope, $receive, $send) = @_;
            my $start = time();
            my $status;

            # Intercept send to capture status
            my $wrapped_send = $self->intercept_send($send, async sub  {
        my ($event, $orig_send) = @_;
                if ($event->{type} eq 'http.response.start') {
                    $status = $event->{status};
                }
                await $orig_send->($event);
            });

            # Call inner app
            await $app->($scope, $receive, $wrapped_send);

            # Log after completion
            my $duration = time() - $start;
            warn sprintf("%s %s %d %.3fs\n",
                $scope->{method}, $scope->{path}, $status // 0, $duration);
        };
    }

=head1 SEE ALSO

L<PAGI::Middleware::Builder> - DSL for composing middleware

=cut
