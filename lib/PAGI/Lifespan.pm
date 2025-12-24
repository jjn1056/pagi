package PAGI::Lifespan;

use strict;
use warnings;
use Future::AsyncAwait;
use Carp qw(croak);

our $VERSION = '0.01';

sub new {
    my ($class, %args) = @_;

    my $app = delete $args{app}
        or croak "PAGI::Lifespan requires 'app' parameter";

    return bless {
        app      => $app,
        startup  => $args{startup},
        shutdown => $args{shutdown},
        _state   => {},
    }, $class;
}

sub state { shift->{_state} }

sub wrap {
    my ($class, $app, %args) = @_;

    my $self = $class->new(app => $app, %args);
    return $self->to_app;
}

sub to_app {
    my ($self) = @_;

    my $app      = $self->{app};
    my $startup  = $self->{startup};
    my $shutdown = $self->{shutdown};
    my $state    = $self->{_state};

    return async sub {
        my ($scope, $receive, $send) = @_;

        my $type = $scope->{type} // '';

        if ($type eq 'lifespan') {
            await _handle_lifespan($state, $startup, $shutdown, $receive, $send);
            return;
        }

        # Inject state into scope for all other request types
        $scope->{'pagi.state'} = $state;

        await $app->($scope, $receive, $send);
    };
}

async sub _handle_lifespan {
    my ($state, $startup, $shutdown, $receive, $send) = @_;

    while (1) {
        my $msg = await $receive->();
        my $type = $msg->{type} // '';

        if ($type eq 'lifespan.startup') {
            if ($startup) {
                eval { await $startup->($state) };
                if ($@) {
                    await $send->({
                        type    => 'lifespan.startup.failed',
                        message => "$@",
                    });
                    return;
                }
            }
            await $send->({ type => 'lifespan.startup.complete' });
        }
        elsif ($type eq 'lifespan.shutdown') {
            if ($shutdown) {
                eval { await $shutdown->($state) };
            }
            await $send->({ type => 'lifespan.shutdown.complete' });
            return;
        }
    }
}

1;

__END__

=head1 NAME

PAGI::Lifespan - Wrap a PAGI app with lifecycle management

=head1 SYNOPSIS

    use PAGI::Lifespan;
    use PAGI::App::Router;

    my $router = PAGI::App::Router->new;
    $router->get('/' => sub { ... });

    # Wrap app with lifecycle management
    my $app = PAGI::Lifespan->wrap(
        $router->to_app,
        startup => async sub {
            my ($state) = @_;  # State hash injected into every request
            $state->{db} = DBI->connect(...);
            $state->{config} = { app_name => 'MyApp' };
        },
        shutdown => async sub {
            my ($state) = @_;
            $state->{db}->disconnect;
        },
    );

=head1 DESCRIPTION

PAGI::Lifespan wraps any PAGI application with lifecycle management.
It handles C<lifespan.startup> and C<lifespan.shutdown> events and
injects application state into the scope for all requests.

=head2 State Flow

The C<startup> and C<shutdown> callbacks receive a C<$state> hashref
as their first argument. Populate this with database connections,
caches, configuration, etc. This is similar to how Starlette's
lifespan context manager yields state to C<request.state>.

    startup => async sub {
        my ($state) = @_;
        $state->{db} = await connect_to_database();
        $state->{cache} = Cache::Redis->new(...);
    },
    shutdown => async sub {
        my ($state) = @_;
        $state->{db}->disconnect;
    },

For every request, this state is injected into the scope as
C<$scope-E<gt>{'pagi.state'}>. This makes it accessible via:

    $req->state->{db}    # In HTTP handlers
    $ws->state->{db}     # In WebSocket handlers
    $sse->state->{db}    # In SSE handlers

=head1 METHODS

=head2 new

    my $lifespan = PAGI::Lifespan->new(
        app      => $pagi_app,                      # Required
        startup  => async sub { my ($state) = @_; },  # Optional
        shutdown => async sub { my ($state) = @_; },  # Optional
    );

Both C<startup> and C<shutdown> callbacks receive the shared state
hashref as their first argument.

=head2 wrap

    my $app = PAGI::Lifespan->wrap($inner_app, startup => ..., shutdown => ...);

Class method shortcut that creates a wrapper and returns the app coderef.

=head2 to_app

    my $app = $lifespan->to_app;

Returns the wrapped PAGI application coderef.

=head2 state

    my $state = $lifespan->state;

Returns the state hashref.

=head1 SEE ALSO

L<PAGI::App::Router>, L<PAGI::Endpoint::Router>

=cut
