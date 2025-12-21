package PAGI::App::SSE::Pubsub;

use strict;
use warnings;
use Future::AsyncAwait;
use Future;

=head1 NAME

PAGI::App::SSE::Pubsub - Pub/sub Server-Sent Events

=head1 SYNOPSIS

    use PAGI::App::SSE::Pubsub;

    my $app = PAGI::App::SSE::Pubsub->new->to_app;

    # From elsewhere, publish events
    PAGI::App::SSE::Pubsub->publish('news', { data => 'Hello!' });

=cut

# Shared state
my %channels;  # channel => { clients => { id => { send => cb, scope => scope } } }
my $next_id = 1;

sub new {
    my ($class, %args) = @_;

    return bless {
        channel     => $args{channel} // 'default',
        retry       => $args{retry},
        on_connect  => $args{on_connect},
        on_close    => $args{on_close},
        history     => $args{history} // 0,
        headers     => $args{headers} // [],
    }, $class;
}

# Class method to publish events
sub publish {
    my ($class, $channel, $event) = @_;

    return unless $channels{$channel};

    my $data = _format_event($event);
    my $clients = $channels{$channel}{clients};

    for my $id (keys %$clients) {
        my $client = $clients->{$id};
        eval {
            $client->{send}->({
                type => 'http.response.body',
                body => $data,
                more => 1,
            });
        };
        if ($@) {
            $client->{closed} = 1;
            delete $clients->{$id};
        }
    }

    # Store in history if enabled
    if ($channels{$channel}{history_size}) {
        push @{$channels{$channel}{history}}, $event;
        my $max = $channels{$channel}{history_size};
        if (@{$channels{$channel}{history}} > $max) {
            shift @{$channels{$channel}{history}};
        }
    }
}

# Class method to get client count
sub client_count {
    my ($class, $channel) = @_;
    $channel //= undef;

    if ($channel) {
        return 0 unless $channels{$channel};
        return scalar keys %{$channels{$channel}{clients}};
    }
    my $total = 0;
    $total += scalar keys %{$_->{clients}} for values %channels;
    return $total;
}

# Class method to list channels
sub list_channels {
    my ($class) = @_;

    return keys %channels;
}

sub to_app {
    my ($self) = @_;

    my $channel = $self->{channel};
    my $retry = $self->{retry};
    my $on_connect = $self->{on_connect};
    my $on_close = $self->{on_close};
    my $history_size = $self->{history};
    my $extra_headers = $self->{headers};

    return async sub  {
        my ($scope, $receive, $send) = @_;
        die "Unsupported scope type: $scope->{type}" if $scope->{type} ne 'http';

        # Build headers
        my @headers = (
            ['content-type', 'text/event-stream'],
            ['cache-control', 'no-cache'],
            ['connection', 'keep-alive'],
            @$extra_headers,
        );

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => \@headers,
        });

        # Initialize channel
        $channels{$channel} //= {
            clients      => {},
            history      => [],
            history_size => $history_size,
        };

        my $client_id = $next_id++;
        my $client_data = {
            send   => $send,
            scope  => $scope,
            closed => 0,
        };
        $channels{$channel}{clients}{$client_id} = $client_data;

        # Send retry hint
        if (defined $retry) {
            await $send->({
                type => 'http.response.body',
                body => "retry: $retry\n\n",
                more => 1,
            });
        }

        # Send history if requested
        my $last_event_id = _get_last_event_id($scope);
        if ($history_size && defined $last_event_id) {
            my $found = 0;
            for my $event (@{$channels{$channel}{history}}) {
                if ($found) {
                    await $send->({
                        type => 'http.response.body',
                        body => _format_event($event),
                        more => 1,
                    });
                } elsif ($event->{id} && $event->{id} eq $last_event_id) {
                    $found = 1;
                }
            }
        }

        $on_connect->($scope, $channel) if $on_connect;

        # Wait for disconnect
        while (!$client_data->{closed}) {
            my $event = await $receive->();
            if ($event->{type} eq 'http.disconnect') {
                last;
            }
        }

        # Cleanup
        delete $channels{$channel}{clients}{$client_id};
        delete $channels{$channel} if !keys %{$channels{$channel}{clients}};

        $on_close->($scope, $channel) if $on_close;

        # End response
        unless ($client_data->{closed}) {
            await $send->({
                type => 'http.response.body',
                body => '',
                more => 0,
            });
        }
    };
}

sub _format_event {
    my ($event) = @_;

    my $data = '';

    if ($event->{event}) {
        $data .= "event: $event->{event}\n";
    }
    if ($event->{id}) {
        $data .= "id: $event->{id}\n";
    }

    my $content = $event->{data} // '';
    for my $line (split /\n/, $content) {
        $data .= "data: $line\n";
    }

    return "$data\n";
}

sub _get_last_event_id {
    my ($scope) = @_;

    for my $h (@{$scope->{headers} // []}) {
        if (lc($h->[0]) eq 'last-event-id') {
            return $h->[1];
        }
    }
    return undef;
}

1;

__END__

=head1 DESCRIPTION

Pub/sub pattern for Server-Sent Events. Clients subscribe to channels
and receive events published to those channels.

=head1 OPTIONS

=over 4

=item * C<channel> - Channel name (default: 'default')

=item * C<retry> - Reconnection time in milliseconds

=item * C<history> - Number of events to keep for replay

=item * C<on_connect> - Callback when client connects

=item * C<on_close> - Callback when client disconnects

=item * C<headers> - Additional response headers

=back

=head1 CLASS METHODS

=head2 publish($channel, $event)

Publish an event to all subscribers of a channel.

    PAGI::App::SSE::Pubsub->publish('news', {
        event => 'update',
        id    => '123',
        data  => 'News content here',
    });

=head2 client_count($channel)

Get number of connected clients, optionally filtered by channel.

=head2 list_channels()

Get list of active channel names.

=cut
