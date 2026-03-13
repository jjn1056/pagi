package PAGI::Test::WebSocket;

use strict;
use warnings;
use Future::AsyncAwait;
use Future;
use Carp qw(croak);


sub new {
    my ($class, %args) = @_;

    croak "app is required" unless $args{app};
    croak "scope is required" unless $args{scope};

    return bless {
        app         => $args{app},
        scope       => $args{scope},
        send_queue  => [],      # Messages from test -> app
        recv_queue  => [],      # Messages from app -> test
        closed      => 0,
        accepted    => 0,
        close_code  => undef,
        close_reason => '',
        _pending_receives => [],  # Pending receive futures
    }, $class;
}

sub _start {
    my ($self) = @_;

    # Create receive coderef for the app
    my $receive = async sub {
        # First call returns websocket.connect
        if (!$self->{_connect_sent}) {
            $self->{_connect_sent} = 1;
            return { type => 'websocket.connect' };
        }

        # Return queued message if available
        if (@{$self->{send_queue}}) {
            return shift @{$self->{send_queue}};
        }

        # Return disconnect if closed
        if ($self->{closed}) {
            return { type => 'websocket.disconnect', code => $self->{close_code} // 1000 };
        }

        # Create a future that will be resolved when data arrives
        my $future = Future->new;
        push @{$self->{_pending_receives}}, $future;
        return await $future;
    };

    # Create send coderef for the app
    my $send = async sub {
        my ($event) = @_;

        if ($event->{type} eq 'websocket.accept') {
            $self->{accepted} = 1;
        }
        elsif ($event->{type} eq 'websocket.send') {
            push @{$self->{recv_queue}}, $event;
        }
        elsif ($event->{type} eq 'websocket.close') {
            $self->{closed} = 1;
            $self->{close_code} = $event->{code} // 1000;
            $self->{close_reason} = $event->{reason} // '';
        }

        return;
    };

    # Start the app future but don't block on it
    $self->{app_future} = $self->{app}->($self->{scope}, $receive, $send);

    # Wait for acceptance (the first two awaits in the app should complete immediately)
    # This is a bit hacky but works: we need to let the app run until it accepts
    $self->_pump_app;

    croak "WebSocket connection not accepted" unless $self->{accepted};

    return $self;
}

sub _pump_app {
    my ($self) = @_;

    # This pumps the app future by checking if it's waiting on a receive
    # If there are pending receives and we have data, resolve them
    while (@{$self->{_pending_receives}} && @{$self->{send_queue}}) {
        my $future = shift @{$self->{_pending_receives}};
        my $event = shift @{$self->{send_queue}};
        $future->done($event);
    }

    # If closed and there are pending receives, resolve them with disconnect
    if ($self->{closed} && @{$self->{_pending_receives}}) {
        while (my $future = shift @{$self->{_pending_receives}}) {
            $future->done({ type => 'websocket.disconnect', code => $self->{close_code} // 1000 });
        }
    }
}

sub send_text {
    my ($self, $text) = @_;

    croak "Cannot send on closed WebSocket" if $self->{closed};

    push @{$self->{send_queue}}, {
        type => 'websocket.receive',
        text => $text,
    };

    # Pump the app to process this message
    $self->_pump_app;

    return $self;
}

sub send_bytes {
    my ($self, $bytes) = @_;

    croak "Cannot send on closed WebSocket" if $self->{closed};

    push @{$self->{send_queue}}, {
        type => 'websocket.receive',
        bytes => $bytes,
    };

    # Pump the app to process this message
    $self->_pump_app;

    return $self;
}

sub send_json {
    my ($self, $data) = @_;

    require JSON::MaybeXS;
    my $text = JSON::MaybeXS::encode_json($data);

    return $self->send_text($text);
}

sub receive_text {
    my ($self, $timeout) = @_;
    $timeout //= 5;

    # Check if we have a text message already waiting
    for my $i (0 .. $#{$self->{recv_queue}}) {
        my $event = $self->{recv_queue}[$i];
        if ($event->{type} eq 'websocket.send' && exists $event->{text}) {
            splice @{$self->{recv_queue}}, $i, 1;
            return $event->{text};
        }
    }

    # Check if connection closed
    return undef if $self->{closed};

    # No message available yet
    croak "Timeout waiting for WebSocket text message";
}

sub receive_bytes {
    my ($self, $timeout) = @_;
    $timeout //= 5;

    # Check if we have a bytes message waiting
    for my $i (0 .. $#{$self->{recv_queue}}) {
        my $event = $self->{recv_queue}[$i];
        if ($event->{type} eq 'websocket.send' && exists $event->{bytes}) {
            splice @{$self->{recv_queue}}, $i, 1;
            return $event->{bytes};
        }
    }

    # Check if connection closed
    return undef if $self->{closed};

    # No message available yet
    croak "Timeout waiting for WebSocket bytes message";
}

sub receive_json {
    my ($self, $timeout) = @_;

    my $text = $self->receive_text($timeout);
    return undef unless defined $text;

    require JSON::MaybeXS;
    return JSON::MaybeXS::decode_json($text);
}

sub close {
    my ($self, $code, $reason) = @_;

    return if $self->{closed};

    $code //= 1000;
    $reason //= '';

    $self->{closed} = 1;
    $self->{close_code} = $code;
    $self->{close_reason} = $reason;

    # Push disconnect event
    push @{$self->{send_queue}}, {
        type => 'websocket.disconnect',
        code => $code,
        reason => $reason,
    };

    # Pump the app to let it process the disconnect
    $self->_pump_app;

    return $self;
}

sub close_code {
    my ($self) = @_;
    return $self->{close_code};
}

sub close_reason {
    my ($self) = @_;
    return $self->{close_reason};
}

sub is_closed {
    my ($self) = @_;
    return $self->{closed};
}

1;

__END__

=head1 NAME

PAGI::Test::WebSocket - WebSocket connection for testing PAGI applications

=head1 SYNOPSIS

    use PAGI::Test::Client;

    my $client = PAGI::Test::Client->new(app => $ws_app);

    # Callback style (auto-close)
    $client->websocket('/ws', sub {
        my ($ws) = @_;
        $ws->send_text('hello');
        is $ws->receive_text, 'echo: hello';
    });

    # Explicit style
    my $ws = $client->websocket('/ws');
    $ws->send_text('hello');
    is $ws->receive_text, 'echo: hello';
    $ws->close;

    # JSON convenience
    $ws->send_json({ action => 'ping' });
    my $data = $ws->receive_json;

=head1 DESCRIPTION

PAGI::Test::WebSocket provides a test client for WebSocket connections in
PAGI applications. It handles the WebSocket protocol handshake and message
exchange, making it easy to test WebSocket endpoints without starting a
real server.

This module is typically used via L<PAGI::Test::Client>'s C<websocket>
method rather than directly.

B<This module is a simplified in-process model of a WebSocket connection.>
It is useful for testing application-level message flow, but it does B<not>
fully emulate transport timing, protocol validation, or network buffering.

=head1 CONSTRUCTOR

=head2 new

    my $ws = PAGI::Test::WebSocket->new(
        app   => $app,     # Required: PAGI app coderef
        scope => $scope,   # Required: WebSocket scope hashref
    );

Creates a new WebSocket test connection. Typically you don't call this
directly; use L<PAGI::Test::Client>'s C<websocket> method instead.

=head1 METHODS

=head2 send_text

    $ws->send_text('Hello, server!');

Sends a text message to the WebSocket application.

=head2 send_bytes

    $ws->send_bytes("\x00\x01\x02\x03");

Sends a binary message to the WebSocket application.

=head2 send_json

    $ws->send_json({ action => 'ping', id => 123 });

Encodes a Perl data structure as JSON and sends it as a text message.

=head2 receive_text

    my $text = $ws->receive_text;
    my $text = $ws->receive_text($timeout);  # custom timeout in seconds

Waits for and returns the next text message from the server. Returns undef
if the connection is closed.

B<Current limitation:> this method does not actually block or wait for the
timeout duration. If no queued text message is immediately available, it
throws an exception right away.

Only returns text messages; binary messages are skipped.

=head2 receive_bytes

    my $bytes = $ws->receive_bytes;
    my $bytes = $ws->receive_bytes($timeout);

Waits for and returns the next binary message from the server. Returns undef
if the connection is closed.

B<Current limitation:> this method does not actually block or wait for the
timeout duration. If no queued binary message is immediately available, it
throws an exception right away.

Only returns binary messages; text messages are skipped.

=head2 receive_json

    my $data = $ws->receive_json;
    my $data = $ws->receive_json($timeout);

Waits for a text message, decodes it as JSON, and returns the resulting
Perl data structure. Dies if the message is not valid JSON.

=head1 LIMITATIONS

=over 4

=item *

This helper does not simulate real WebSocket framing, network buffering,
backpressure, or wire-level timing behavior.

=item *

The receive timeout arguments are advisory only at present; receive methods
check the current queue immediately rather than waiting asynchronously.

=item *

For protocol-compliance, keepalive timing, or transport-level edge cases,
test against L<PAGI::Server> and a real WebSocket client.

=back

=head2 close

    $ws->close;
    $ws->close($code);
    $ws->close($code, $reason);

Closes the WebSocket connection. Default close code is 1000 (normal closure).

=head2 close_code

    my $code = $ws->close_code;

Returns the WebSocket close code if the connection has been closed, or
undef if still open.

=head2 close_reason

    my $reason = $ws->close_reason;

Returns the WebSocket close reason if the connection has been closed, or
an empty string if still open.

=head2 is_closed

    if ($ws->is_closed) {
        say "Connection closed";
    }

Returns true if the WebSocket connection has been closed.

=head1 INTERNAL METHODS

=head2 _start

    $ws->_start;

Internal method called by L<PAGI::Test::Client> to start the WebSocket
connection, send the initial connect event, and wait for acceptance.

=head1 WEBSOCKET PROTOCOL

This module implements the PAGI WebSocket protocol:

=over 4

=item 1. Test sends C<websocket.connect> event

=item 2. App sends C<websocket.accept> event

=item 3. Test sends C<websocket.receive> events with C<text> or C<bytes>

=item 4. App sends C<websocket.send> events with C<text> or C<bytes>

=item 5. Either side sends C<websocket.disconnect> or C<websocket.close>

=back

=head1 EXAMPLE

    use Test2::V0;
    use PAGI::Test::Client;
    use Future::AsyncAwait;

    # Simple echo WebSocket app
    my $ws_app = async sub {
        my ($scope, $receive, $send) = @_;
        return unless $scope->{type} eq 'websocket';

        my $event = await $receive->();
        return unless $event->{type} eq 'websocket.connect';

        await $send->({ type => 'websocket.accept' });

        while (1) {
            my $msg = await $receive->();
            last if $msg->{type} eq 'websocket.disconnect';

            if (defined $msg->{text}) {
                await $send->({
                    type => 'websocket.send',
                    text => "echo: $msg->{text}"
                });
            }
        }
    };

    # Test it
    my $client = PAGI::Test::Client->new(app => $ws_app);
    $client->websocket('/ws', sub {
        my ($ws) = @_;
        $ws->send_text('hello');
        is $ws->receive_text, 'echo: hello', 'echoed text';
    });

=head1 SEE ALSO

L<PAGI::Test::Client>, L<PAGI::Test::Response>, L<PAGI::WebSocket>

=head1 AUTHOR

PAGI Contributors

=cut
