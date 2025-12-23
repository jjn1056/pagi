package PAGI::Background;

use strict;
use warnings;
use Scalar::Util qw(blessed);

our $VERSION = '0.01';

sub new {
    my ($class, $loop) = @_;
    return bless { loop => $loop }, $class;
}

sub add {
    my ($self, $task, @args) = @_;

    my $loop = $self->{loop};

    $loop->later(sub {
        my $result = eval { $task->(@args) };

        if ($@) {
            warn "PAGI: Background task failed: $@\n";
        }
        elsif (blessed($result) && $result->isa('Future')) {
            # Async task - let it run, log failures
            $result->on_fail(sub {
                my ($error) = @_;
                warn "PAGI: Background task failed: $error\n";
            })->retain;  # Prevent garbage collection
        }
    });

    return $self;  # Chainable
}

1;

__END__

=head1 NAME

PAGI::Background - Fire-and-forget background tasks

=head1 SYNOPSIS

    # Available in all request handlers via $scope->{background}

    # HTTP - run after response is sent
    async sub handler {
        my ($scope, $receive, $send) = @_;

        $scope->{background}
            ->add(\&send_welcome_email, $user->email)
            ->add(\&log_analytics, 'signup', $user->id);

        await $send->({ type => 'http.response.start', status => 200, ... });
        await $send->({ type => 'http.response.body', body => $json, more => 0 });
        # Tasks run on event loop after handler returns
    }

    # WebSocket - process without blocking next message
    async sub on_receive {
        my ($self, $ws, $data) = @_;

        await $ws->send_json({ status => 'received' });

        # Heavy work doesn't block the message loop
        $ws->scope->{background}->add(\&process_message, $data);
    }

    # SSE - fire alongside the event stream
    async sub on_connect {
        my ($self, $sse) = @_;

        await $sse->send_event(data => 'connected');

        $sse->scope->{background}->add(\&notify_presence, $user_id);
    }

=head1 DESCRIPTION

PAGI::Background provides a simple way to run tasks without blocking
the current request/response cycle. Tasks are scheduled on the event
loop and run after the current synchronous work yields.

This is useful for:

=over 4

=item * Sending emails after signup

=item * Logging to external services

=item * Analytics and tracking

=item * Cleanup operations

=item * Notifications to other services

=back

=head1 METHODS

=head2 new

    my $bg = PAGI::Background->new($loop);

Creates a new background task manager. Typically you don't call this
directly - the server injects C<< $scope->{background} >> for you.

=head2 add

    $scope->{background}->add(\&task, @args);
    $scope->{background}->add(sub { ... });
    $scope->{background}->add(async sub { await ... });

Schedules a task to run on the event loop. The task runs after the
current synchronous work completes.

B<Arguments:>

=over 4

=item * C<$task> - Coderef (sync or async sub)

=item * C<@args> - Arguments to pass to the task

=back

B<Returns:> C<$self> for chaining.

B<Error handling:> Errors are logged to STDERR but don't affect the
response (which has already been sent).

=head1 TIMING

Tasks run when the event loop processes them, which is after the
current handler yields:

    HTTP:      handler runs -> response sent -> handler returns -> [tasks run]
    WebSocket: on_receive   -> send response -> returns         -> [tasks run]
    SSE:       send_event   -> returns                          -> [tasks run]

Multiple tasks added in one handler all run, but order is not
guaranteed (they're independent operations on the event loop).

=head1 ASYNC TASKS

Tasks can be async subs that return Futures:

    $scope->{background}->add(async sub {
        await $http->POST('https://analytics.example.com/event', ...);
    });

The Future is retained (not garbage collected) and failures are logged.

=head1 SEE ALSO

L<PAGI::Response>, L<PAGI::WebSocket>, L<PAGI::SSE>

=cut
