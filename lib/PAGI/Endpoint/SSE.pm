package PAGI::Endpoint::SSE;

use strict;
use warnings;

use Future::AsyncAwait;
use Carp qw(croak);

# Factory class method - override in subclass for customization
sub context_class { 'PAGI::Context' }

# Keepalive interval in seconds (0 = disabled)
sub keepalive_interval { 0 }

sub new {
    my ($class, %args) = @_;
    return bless \%args, $class;
}

async sub handle {
    my ($self, $ctx) = @_;
    my $sse = $ctx->sse;

    # Configure keepalive if specified
    my $keepalive = $self->keepalive_interval;
    if ($keepalive > 0) {
        $sse->keepalive($keepalive);
    }

    # Register disconnect callback
    if ($self->can('on_disconnect')) {
        $sse->on_close(sub {
            $self->on_disconnect($ctx);
        });
    }

    # Call on_connect if defined
    if ($self->can('on_connect')) {
        await $self->on_connect($ctx);
    } else {
        # Default: just start the stream
        await $sse->start;
    }

    # Wait for disconnect
    await $sse->run;
}

sub to_app {
    my ($class) = @_;
    my $context_class = $class->context_class;

    return async sub {
        my ($scope, $receive, $send) = @_;

        my $type = $scope->{type} // '';
        croak "Expected sse scope, got '$type'" unless $type eq 'sse';

        require PAGI::Context;
        my $endpoint = $class->new;
        my $ctx = $context_class->new($scope, $receive, $send);

        await $endpoint->handle($ctx);
    };
}

1;

__END__

=head1 NAME

PAGI::Endpoint::SSE - Class-based Server-Sent Events endpoint handler

=head1 SYNOPSIS

    package MyApp::Notifications;
    use parent 'PAGI::Endpoint::SSE';
    use Future::AsyncAwait;

    sub keepalive_interval { 30 }

    async sub on_connect {
        my ($self, $ctx) = @_;
        my $user_id = $ctx->stash->get('user_id');

        await $ctx->sse->send_event(
            event => 'connected',
            data  => { user_id => $user_id },
        );
    }

    sub on_disconnect {
        my ($self, $ctx) = @_;
        # Cleanup subscriptions
    }

    # Use with PAGI server
    my $app = MyApp::Notifications->to_app;

=head1 DESCRIPTION

PAGI::Endpoint::SSE provides a class-based approach to handling
Server-Sent Events connections with lifecycle hooks.

=head1 LIFECYCLE METHODS

=head2 on_connect

    async sub on_connect {
        my ($self, $ctx) = @_;
        await $ctx->sse->send_event(data => 'Hello!');
    }

Called when a client connects. The SSE stream is automatically
started before this is called. Use this to send initial events
and set up subscriptions.

=head2 on_disconnect

    sub on_disconnect {
        my ($self, $ctx) = @_;
        # Cleanup subscriptions
    }

Called when connection closes. This is synchronous (not async).

=head1 CLASS METHODS

=head2 keepalive_interval

    sub keepalive_interval { 30 }

Seconds between keepalive pings. Set to 0 to disable (default).

=head2 context_class

    sub context_class { 'PAGI::Context' }

Override to use a custom context class.

=head2 to_app

    my $app = MyEndpoint->to_app;

Returns a PAGI-compatible async coderef.

=head1 RECIPES

=head2 Multi-Process Broadcasting with Redis

The simple in-memory subscriber pattern only works with a single process:

    my %subscribers;  # Lost when worker dies, not shared between workers

For multi-process deployments (e.g., C<pagi-server --workers 4>), use Redis
pub/sub as a message bus between workers. Each worker keeps its own local
subscriber hash with real connection objects, and Redis broadcasts messages
between workers.

    package MyApp::Events;
    use parent 'PAGI::Endpoint::SSE';
    use Future::AsyncAwait;
    use JSON::MaybeXS qw(encode_json decode_json);

    my %subscribers;  # Local to this process
    my $redis;        # Redis connection

    # Call this once at server startup (e.g., in lifespan handler)
    sub setup_redis {
        my ($redis_url) = @_;
        $redis = Redis::Async->new(server => $redis_url);

        # Subscribe to channel - forward to local connections
        $redis->subscribe('events', sub {
            my ($message) = @_;
            my $data = decode_json($message);
            _local_broadcast($data);
        });
    }

    # Broadcast to local process connections only
    sub _local_broadcast {
        my ($message) = @_;
        for my $sse (values %subscribers) {
            $sse->try_send_json($message);
        }
    }

    # Public API: publish to Redis (all workers receive it)
    sub broadcast {
        my ($message) = @_;
        $redis->publish('events', encode_json($message));
    }

    # Track local connections
    my $sub_id = 0;

    async sub on_connect {
        my ($self, $ctx) = @_;
        my $sse = $ctx->sse;
        my $id = ++$sub_id;
        $subscribers{$id} = $sse;
        $ctx->stash->set(sub_id => $id);

        await $sse->send_event(
            event => 'connected',
            data  => { subscriber_id => $id },
        );
    }

    sub on_disconnect {
        my ($self, $ctx) = @_;
        delete $subscribers{$ctx->stash->get('sub_id')};
    }

Now when any worker calls C<broadcast()>, the message goes to Redis, and
every worker (including itself) receives it and forwards to their local
SSE connections.

Setup Redis in your lifespan handler:

    my $app = async sub {
        my ($scope, $receive, $send) = @_;

        if ($scope->{type} eq 'lifespan') {
            my $event = await $receive->();
            if ($event->{type} eq 'lifespan.startup') {
                MyApp::Events::setup_redis('redis://localhost:6379');
                await $send->({ type => 'lifespan.startup.complete' });
            }
            # ... shutdown handling
            return;
        }

        # ... route to SSE endpoint
    };

=head1 SEE ALSO

L<PAGI::Context>, L<PAGI::SSE>, L<PAGI::Endpoint::HTTP>,
L<PAGI::Endpoint::WebSocket>

=cut
