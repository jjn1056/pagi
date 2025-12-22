package PAGI::SSE;
use strict;
use warnings;
use Carp qw(croak);
use Hash::MultiValue;
use Future::AsyncAwait;
use Future;
use JSON::PP ();
use Scalar::Util qw(blessed);

our $VERSION = '0.01';

sub new {
    my ($class, $scope, $receive, $send) = @_;

    croak "PAGI::SSE requires scope hashref"
        unless $scope && ref($scope) eq 'HASH';
    croak "PAGI::SSE requires receive coderef"
        unless $receive && ref($receive) eq 'CODE';
    croak "PAGI::SSE requires send coderef"
        unless $send && ref($send) eq 'CODE';
    croak "PAGI::SSE requires scope type 'sse', got '$scope->{type}'"
        unless ($scope->{type} // '') eq 'sse';

    return bless {
        scope     => $scope,
        receive   => $receive,
        send      => $send,
        _state    => 'pending',  # pending -> started -> closed
        _on_close => [],
        _on_error => [],
        _stash    => {},
    }, $class;
}

# Scope property accessors
sub scope        { shift->{scope} }
sub path         { shift->{scope}{path} // '/' }
sub raw_path     { my $s = shift; $s->{scope}{raw_path} // $s->{scope}{path} // '/' }
sub query_string { shift->{scope}{query_string} // '' }
sub scheme       { shift->{scope}{scheme} // 'http' }
sub http_version { shift->{scope}{http_version} // '1.1' }
sub client       { shift->{scope}{client} }
sub server       { shift->{scope}{server} }

# Per-connection storage
sub stash        { shift->{_stash} }

# State accessors
sub state { shift->{_state} }

sub is_started {
    my $self = shift;
    return $self->{_state} eq 'started';
}

sub is_closed {
    my $self = shift;
    return $self->{_state} eq 'closed';
}

# Internal state setters
sub _set_state {
    my ($self, $state) = @_;
    $self->{_state} = $state;
}

sub _set_closed {
    my ($self) = @_;
    $self->{_state} = 'closed';

    # Stop keepalive timer if running
    if ($self->{_keepalive_timer}) {
        $self->{_keepalive_timer}->stop;
        if ($self->{_loop}) {
            $self->{_loop}->remove($self->{_keepalive_timer});
        }
        delete $self->{_keepalive_timer};
    }
}

# Start the SSE stream
async sub start {
    my ($self, %opts) = @_;

    # Idempotent - don't start twice
    return $self if $self->is_started || $self->is_closed;

    my $event = {
        type   => 'sse.start',
        status => $opts{status} // 200,
    };
    $event->{headers} = $opts{headers} if exists $opts{headers};

    await $self->{send}->($event);
    $self->_set_state('started');

    return $self;
}

# Set or get the event loop
sub set_loop {
    my ($self, $loop) = @_;
    $self->{_loop} = $loop;
    return $self;
}

sub loop {
    my ($self) = @_;
    return $self->{_loop} if $self->{_loop};

    require IO::Async::Loop;
    $self->{_loop} = IO::Async::Loop->new;
    return $self->{_loop};
}

# Enable/disable keepalive timer
sub keepalive {
    my ($self, $interval, $comment) = @_;
    $comment //= ':keepalive';

    # Stop existing timer if any
    if ($self->{_keepalive_timer}) {
        $self->{_keepalive_timer}->stop;
        $self->loop->remove($self->{_keepalive_timer});
        delete $self->{_keepalive_timer};
    }

    # If interval is 0 or undef, just disable
    return $self unless $interval && $interval > 0;

    require IO::Async::Timer::Periodic;
    require Scalar::Util;

    my $weak_self = $self;
    Scalar::Util::weaken($weak_self);

    my $timer = IO::Async::Timer::Periodic->new(
        interval => $interval,
        on_tick  => sub {
            return unless $weak_self && !$weak_self->is_closed;
            $weak_self->try_send($comment);
        },
    );

    $self->loop->add($timer);
    $timer->start;
    $self->{_keepalive_timer} = $timer;

    return $self;
}

# Single header lookup (case-insensitive, returns last value)
sub header {
    my ($self, $name) = @_;
    $name = lc($name);
    my $value;
    for my $pair (@{$self->{scope}{headers} // []}) {
        if (lc($pair->[0]) eq $name) {
            $value = $pair->[1];
        }
    }
    return $value;
}

# All headers as Hash::MultiValue (cached)
sub headers {
    my $self = shift;
    return $self->{_headers} if $self->{_headers};

    my @pairs;
    for my $pair (@{$self->{scope}{headers} // []}) {
        push @pairs, lc($pair->[0]), $pair->[1];
    }

    $self->{_headers} = Hash::MultiValue->new(@pairs);
    return $self->{_headers};
}

# All values for a header
sub header_all {
    my ($self, $name) = @_;
    return $self->headers->get_all(lc($name));
}

# Get Last-Event-ID header from client (for reconnection)
sub last_event_id {
    my ($self) = @_;
    return $self->header('last-event-id');
}

# Send data-only event
async sub send {
    my ($self, $data) = @_;

    croak "Cannot send on closed SSE connection" if $self->is_closed;

    # Auto-start if not started
    await $self->start unless $self->is_started;

    await $self->{send}->({
        type => 'sse.send',
        data => $data,
    });

    return $self;
}

# Send JSON-encoded data
async sub send_json {
    my ($self, $data) = @_;

    croak "Cannot send on closed SSE connection" if $self->is_closed;

    await $self->start unless $self->is_started;

    my $json = JSON::PP::encode_json($data);

    await $self->{send}->({
        type => 'sse.send',
        data => $json,
    });

    return $self;
}

# Send full SSE event with all fields
async sub send_event {
    my ($self, %opts) = @_;

    croak "Cannot send on closed SSE connection" if $self->is_closed;
    croak "send_event requires 'data' parameter" unless exists $opts{data};

    await $self->start unless $self->is_started;

    # Auto-encode hashref/arrayref data as JSON
    my $data = $opts{data};
    if (ref $data) {
        $data = JSON::PP::encode_json($data);
    }

    my $event = {
        type => 'sse.send',
        data => $data,
    };

    $event->{event} = $opts{event} if defined $opts{event};
    $event->{id}    = "$opts{id}"  if defined $opts{id};
    $event->{retry} = int($opts{retry}) if defined $opts{retry};

    await $self->{send}->($event);

    return $self;
}

# Safe send - returns bool instead of throwing
async sub try_send {
    my ($self, $data) = @_;
    return 0 if $self->is_closed;

    eval {
        await $self->start unless $self->is_started;
        await $self->{send}->({
            type => 'sse.send',
            data => $data,
        });
    };
    if ($@) {
        $self->_set_closed;
        return 0;
    }
    return 1;
}

async sub try_send_json {
    my ($self, $data) = @_;
    return 0 if $self->is_closed;

    eval {
        await $self->start unless $self->is_started;
        my $json = JSON::PP::encode_json($data);
        await $self->{send}->({
            type => 'sse.send',
            data => $json,
        });
    };
    if ($@) {
        $self->_set_closed;
        return 0;
    }
    return 1;
}

async sub try_send_event {
    my ($self, %opts) = @_;
    return 0 if $self->is_closed;

    eval {
        await $self->start unless $self->is_started;

        my $data = $opts{data} // '';
        if (ref $data) {
            $data = JSON::PP::encode_json($data);
        }

        my $event = {
            type => 'sse.send',
            data => $data,
        };
        $event->{event} = $opts{event} if defined $opts{event};
        $event->{id}    = "$opts{id}"  if defined $opts{id};
        $event->{retry} = int($opts{retry}) if defined $opts{retry};

        await $self->{send}->($event);
    };
    if ($@) {
        $self->_set_closed;
        return 0;
    }
    return 1;
}

# Register close callback
sub on_close {
    my ($self, $callback) = @_;
    push @{$self->{_on_close}}, $callback;
    return $self;
}

# Register error callback
sub on_error {
    my ($self, $callback) = @_;
    push @{$self->{_on_error}}, $callback;
    return $self;
}

# Internal: run all on_close callbacks
async sub _run_close_callbacks {
    my ($self) = @_;

    # Only run once
    return if $self->{_close_callbacks_ran};
    $self->{_close_callbacks_ran} = 1;

    for my $cb (@{$self->{_on_close}}) {
        eval {
            my $r = $cb->($self);
            if (blessed($r) && $r->isa('Future')) {
                await $r;
            }
        };
        if ($@) {
            warn "PAGI::SSE on_close callback error: $@";
        }
    }
}

# Close the connection
sub close {
    my ($self) = @_;

    return $self if $self->is_closed;

    $self->_set_closed;
    $self->_run_close_callbacks->get;

    return $self;
}

# Wait for disconnect
async sub run {
    my ($self) = @_;

    await $self->start unless $self->is_started;

    while (!$self->is_closed) {
        my $event = await $self->{receive}->();
        my $type = $event->{type} // '';

        if ($type eq 'sse.disconnect') {
            $self->_set_closed;
            await $self->_run_close_callbacks;
            last;
        }
    }

    return;
}

1;

__END__

=head1 NAME

PAGI::SSE - Convenience wrapper for PAGI Server-Sent Events connections

=head1 SYNOPSIS

    use PAGI::SSE;
    use Future::AsyncAwait;

    # Simple event stream
    async sub app {
        my ($scope, $receive, $send) = @_;

        my $sse = PAGI::SSE->new($scope, $receive, $send);
        await $sse->start;

        # Send events
        await $sse->send_event("Hello, SSE!");
        await $sse->send_event("Named event", event => 'custom');
        await $sse->send_json({ temperature => 72 });
    }

=head1 DESCRIPTION

PAGI::SSE wraps the raw PAGI SSE protocol to provide a clean,
high-level API for Server-Sent Events connections.

=head1 CONSTRUCTOR

=head2 new

    my $sse = PAGI::SSE->new($scope, $receive, $send);

Creates a new SSE wrapper. Requires:

=over 4

=item * C<$scope> - PAGI scope hashref with C<type => 'sse'>

=item * C<$receive> - Async coderef returning Futures for events

=item * C<$send> - Async coderef for sending events

=back

Dies if scope type is not 'sse'.

=head1 SCOPE ACCESSORS

=head2 scope, path, raw_path, query_string, scheme, http_version

    my $path = $sse->path;              # /events
    my $qs = $sse->query_string;        # token=abc
    my $scheme = $sse->scheme;          # http or https

Standard PAGI scope properties with sensible defaults.

=head2 client, server

    my $client = $sse->client;          # ['192.168.1.1', 54321]

Client and server address info.

=head2 header, headers, header_all

    my $last_id = $sse->header('last-event-id');
    my $all_cookies = $sse->header_all('cookie');
    my $hmv = $sse->headers;            # Hash::MultiValue

Case-insensitive header access.

=head2 stash

    $sse->stash->{user} = $user;
    my $session = $sse->stash->{session};

Per-connection storage hashref. Useful for storing user data
without external variables.

=head1 AUTHOR

PAGI Contributors

=cut
