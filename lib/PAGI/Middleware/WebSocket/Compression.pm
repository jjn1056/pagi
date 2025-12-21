package PAGI::Middleware::WebSocket::Compression;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;

=head1 NAME

PAGI::Middleware::WebSocket::Compression - WebSocket per-message compression

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'WebSocket::Compression',
            level => 6,
            min_size => 128;
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::WebSocket::Compression implements per-message deflate
compression (RFC 7692) for WebSocket connections. It negotiates the
permessage-deflate extension and transparently compresses/decompresses
messages.

=head1 CONFIGURATION

=over 4

=item * level (default: 6)

Compression level (1-9). Higher = better compression, slower.

=item * min_size (default: 128)

Minimum message size to compress. Messages smaller than this are sent
uncompressed.

=item * server_no_context_takeover (default: 0)

If true, don't use context takeover for server-to-client messages.

=item * client_no_context_takeover (default: 0)

If true, request client to not use context takeover.

=back

=cut

sub _init {
    my ($self, $config) = @_;

    $self->{level} = $config->{level} // 6;
    $self->{min_size} = $config->{min_size} // 128;
    $self->{server_no_context_takeover} = $config->{server_no_context_takeover} // 0;
    $self->{client_no_context_takeover} = $config->{client_no_context_takeover} // 0;
}

sub wrap {
    my ($self, $app) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        # Only apply to WebSocket connections
        if ($scope->{type} ne 'websocket') {
            await $app->($scope, $receive, $send);
            return;
        }

        # Check if client offered permessage-deflate
        my $extensions = $self->_parse_extensions($scope);
        my $has_deflate = exists $extensions->{'permessage-deflate'};

        unless ($has_deflate) {
            # No compression support, pass through
            await $app->($scope, $receive, $send);
            return;
        }

        # Try to load Compress::Raw::Zlib
        my $have_zlib = eval { require Compress::Raw::Zlib; 1 };
        unless ($have_zlib) {
            await $app->($scope, $receive, $send);
            return;
        }

        # Create compression/decompression streams
        my ($deflator, $inflator);
        my $compression_active = 0;

        my $init_streams = sub {
            my ($d_status, $deflate) = Compress::Raw::Zlib::Deflate->new(
                -Level      => $self->{level},
                -WindowBits => -15,  # Raw deflate
                -AppendOutput => 1,
            );
            my ($i_status, $inflate) = Compress::Raw::Zlib::Inflate->new(
                -WindowBits => -15,
                -AppendOutput => 1,
            );

            return ($deflate, $inflate) if $d_status == Compress::Raw::Zlib::Z_OK()
                && $i_status == Compress::Raw::Zlib::Z_OK();
            return;
        };

        # Wrap send to handle compression
        my $wrapped_send = async sub  {
        my ($event) = @_;
            if ($event->{type} eq 'websocket.accept') {
                # Initialize compression streams
                ($deflator, $inflator) = $init_streams->();
                $compression_active = defined $deflator;

                if ($compression_active) {
                    # Add extension to accept response
                    my @extensions = ('permessage-deflate');
                    push @extensions, 'server_no_context_takeover'
                        if $self->{server_no_context_takeover};
                    push @extensions, 'client_no_context_takeover'
                        if $self->{client_no_context_takeover};

                    $event = {
                        %$event,
                        extensions => join('; ', @extensions),
                    };
                }
                await $send->($event);
                return;
            }

            if ($event->{type} eq 'websocket.send' && $compression_active) {
                my $text = $event->{text};
                my $bytes = $event->{bytes};
                my $data = defined $text ? $text : $bytes;

                # Only compress if above min_size
                if (defined $data && length($data) >= $self->{min_size}) {
                    my $compressed = '';
                    my $status = $deflator->deflate($data, $compressed);
                    $status = $deflator->flush($compressed, Compress::Raw::Zlib::Z_SYNC_FLUSH());

                    if ($status == Compress::Raw::Zlib::Z_OK()) {
                        # Remove trailing 0x00 0x00 0xff 0xff
                        $compressed =~ s/\x00\x00\xff\xff$//;

                        $event = {
                            %$event,
                            (defined $text ? (text => undef) : ()),
                            bytes => $compressed,
                            compressed => 1,
                        };

                        # Reset context if no takeover
                        if ($self->{server_no_context_takeover}) {
                            ($deflator, $inflator) = $init_streams->();
                        }
                    }
                }
            }

            await $send->($event);
        };

        # Wrap receive to handle decompression
        my $wrapped_receive = async sub {
            my $event = await $receive->();

            if ($event->{type} eq 'websocket.receive' && $compression_active) {
                if ($event->{compressed}) {
                    my $data = $event->{bytes} // $event->{text};
                    if (defined $data) {
                        # Add trailer bytes
                        $data .= "\x00\x00\xff\xff";

                        my $decompressed = '';
                        my $status = $inflator->inflate($data, $decompressed);

                        if ($status == Compress::Raw::Zlib::Z_OK()) {
                            if (defined $event->{text}) {
                                $event = { %$event, text => $decompressed, bytes => undef };
                            } else {
                                $event = { %$event, bytes => $decompressed };
                            }

                            # Reset context if no takeover
                            if ($self->{client_no_context_takeover}) {
                                ($deflator, $inflator) = $init_streams->();
                            }
                        }
                    }
                }
            }

            return $event;
        };

        # Add compression info to scope
        my $new_scope = {
            %$scope,
            'pagi.websocket.compression' => {
                level    => $self->{level},
                min_size => $self->{min_size},
                available => $has_deflate,
            },
        };

        await $app->($new_scope, $wrapped_receive, $wrapped_send);
    };
}

sub _parse_extensions {
    my ($self, $scope) = @_;

    my %extensions;

    for my $h (@{$scope->{headers} // []}) {
        next unless lc($h->[0]) eq 'sec-websocket-extensions';

        for my $ext (split /\s*,\s*/, $h->[1]) {
            my ($name, @params) = split /\s*;\s*/, $ext;
            $extensions{$name} = \@params;
        }
    }

    return \%extensions;
}

1;

__END__

=head1 REQUIREMENTS

This middleware requires L<Compress::Raw::Zlib> for compression.
If the module is not available, compression is disabled and messages
pass through uncompressed.

=head1 EXTENSION NEGOTIATION

The middleware checks for the C<permessage-deflate> extension in the
client's Sec-WebSocket-Extensions header. If present and zlib is
available, compression is enabled.

The server responds with the negotiated extension parameters in the
websocket.accept event's extensions field.

=head1 SCOPE EXTENSIONS

=over 4

=item * pagi.websocket.compression

Hashref containing C<level>, C<min_size>, and C<available> flags.

=back

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

L<PAGI::Middleware::WebSocket::Heartbeat> - WebSocket keepalive

RFC 7692 - Compression Extensions for WebSocket

=cut
