package PAGI::Lifespan;

use strict;
use warnings;
use Future::AsyncAwait;
use Carp qw(croak);


sub new {
    my ($class, %args) = @_;

    my $app = delete $args{app};

    my @handlers;
    push @handlers, {
        startup  => $args{startup},
        shutdown => $args{shutdown},
    } if $args{startup} || $args{shutdown};

    return bless {
        app       => $app,
        _handlers => \@handlers,
        _state    => undef,
    }, $class;
}

sub state { shift->{_state} }

sub on_startup {
    my ($self, $cb) = @_;
    return $self->register(startup => $cb);
}

sub on_shutdown {
    my ($self, $cb) = @_;
    return $self->register(shutdown => $cb);
}

sub register {
    my ($self, %args) = @_;
    return $self unless $args{startup} || $args{shutdown};
    push @{$self->{_handlers}}, {
        startup  => $args{startup},
        shutdown => $args{shutdown},
    };
    return $self;
}

sub for_scope {
    my ($class, $scope) = @_;
    croak "scope is required" unless $scope && ref($scope) eq 'HASH';
    return $scope->{'pagi.lifespan.manager'} //= $class->new;
}

sub wrap {
    my ($class, $app, %args) = @_;

    my $self = $class->new(app => $app, %args);
    return $self->to_app;
}

sub to_app {
    my ($self) = @_;

    my $app = $self->{app};
    croak "PAGI::Lifespan->to_app requires an app" unless $app;

    my $wrapper = async sub {
        my ($scope, $receive, $send) = @_;

        my $type = $scope->{type} // '';

        if ($type eq 'lifespan') {
            $scope->{'pagi.lifespan.manager'} //= $self;
            $scope->{state} //= {};
            await $app->($scope, $receive, $send);
            return await $self->handle($scope, $receive, $send);
        }

        my $inner_scope = { %$scope };
        $inner_scope->{state} //= ($self->{_state} // {});
        $self->{_state} = $inner_scope->{state};

        await $app->($inner_scope, $receive, $send);
    };

    return $wrapper;
}

async sub handle {
    my ($self, $scope, $receive, $send) = @_;
    return 0 unless $scope && ($scope->{type} // '') eq 'lifespan';
    return 0 if $scope->{'pagi.lifespan.handled'};
    $scope->{'pagi.lifespan.handled'} = 1;

    my @handlers;
    if (my $extra = $scope->{'pagi.lifespan.handlers'}) {
        push @handlers, @$extra;
    }
    push @handlers, @{$self->{_handlers} // []};

    my $state = $scope->{state} //= {};
    $self->{_state} = $state;

    while (1) {
        my $msg = await $receive->();
        my $type = $msg->{type} // '';

        if ($type eq 'lifespan.startup') {
            for my $handler (@handlers) {
                next unless $handler->{startup};
                eval { await $handler->{startup}->($state) };
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
            for my $handler (reverse @handlers) {
                next unless $handler->{shutdown};
                eval { await $handler->{shutdown}->($state) };
            }
            await $send->({ type => 'lifespan.shutdown.complete' });
            return 1;
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
C<$scope-E<gt>{state}>. This makes it accessible via:

    $req->state->{db}    # In HTTP handlers
    $ws->state->{db}     # In WebSocket handlers
    $sse->state->{db}    # In SSE handlers

=head2 Hook Aggregation

Multiple C<PAGI::Lifespan> wrappers can be nested. Each wrapper registers
its C<startup> and C<shutdown> callbacks in C<< $scope->{'pagi.lifespan.handlers'} >>.
Startup callbacks run in registration order (outer to inner), and shutdown
callbacks run in reverse order (inner to outer). The actual application
does not receive lifespan events unless it explicitly handles them.

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
