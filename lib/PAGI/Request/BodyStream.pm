package PAGI::Request::BodyStream;

use strict;
use warnings;

use Future::AsyncAwait;
use Encode qw(decode FB_CROAK FB_DEFAULT LEAVE_SRC);
use Carp qw(croak);


=head1 NAME

PAGI::Request::BodyStream - Streaming body consumption for PAGI requests

=head1 SYNOPSIS

    use PAGI::Request::BodyStream;
    use Future::AsyncAwait;

    # Basic streaming
    my $stream = PAGI::Request::BodyStream->new(receive => $receive);

    while (!$stream->is_done) {
        my $chunk = await $stream->next_chunk;
        last unless defined $chunk;
        print "Got chunk: ", length($chunk), " bytes\n";
    }

    # With size limit
    my $stream = PAGI::Request::BodyStream->new(
        receive   => $receive,
        max_bytes => 1024 * 1024,  # 1MB limit
    );

    # With UTF-8 decoding
    my $stream = PAGI::Request::BodyStream->new(
        receive => $receive,
        decode  => 'UTF-8',
    );

    # Stream to file
    await $stream->stream_to_file('/tmp/upload.dat');

    # Stream to custom sink
    await $stream->stream_to(async sub ($chunk) {
        # Process chunk
        print STDERR "Processing: ", length($chunk), " bytes\n";
    });

=head1 DESCRIPTION

PAGI::Request::BodyStream provides streaming body consumption for large request
bodies. This is useful when you need to process request data incrementally
without loading the entire body into memory.

The stream is pull-based: you call C<next_chunk()> to receive the next chunk
of data. The stream handles:

=over 4

=item * Size limits with customizable error messages

=item * UTF-8 decoding with proper handling of incomplete sequences at chunk boundaries

=item * Client disconnect detection

=item * Convenient file streaming with C<stream_to_file()>

=back

B<Important>: Streaming is mutually exclusive with buffered body methods like
C<body()>, C<json()>, C<form()> in L<PAGI::Request>. Once you start streaming,
you cannot use those methods.

=head1 CONSTRUCTOR

=head2 new

    my $stream = PAGI::Request::BodyStream->new(
        receive    => $receive,      # Required: PAGI receive callback
        max_bytes  => 10485760,      # Optional: max body size
        decode     => 'UTF-8',       # Optional: decode to UTF-8
        strict     => 1,             # Optional: strict UTF-8 (croak on invalid)
        limit_name => 'body_size',   # Optional: name for limit error message
    );

Creates a new body stream.

=over 4

=item * C<receive> - Required. The PAGI receive callback.

=item * C<max_bytes> - Optional. Maximum bytes to read. Throws error if exceeded.

=item * C<decode> - Optional. Encoding to decode chunks to (typically 'UTF-8').

=item * C<strict> - Optional. If true, throw on invalid UTF-8. If false (default),
use replacement characters.

=item * C<limit_name> - Optional. Name to use in error message when max_bytes
is exceeded (default: 'max_bytes').

=back

=cut

sub new {
    my ($class, %args) = @_;
    my $receive = $args{receive} // croak("receive is required");

    my $self = bless {
        receive       => $receive,
        max_bytes     => $args{max_bytes},
        decode        => $args{decode},
        strict        => $args{strict} // 0,
        limit_name    => $args{limit_name} // 'max_bytes',
        _bytes_read   => 0,
        _done         => 0,
        _error        => undef,
        _buffer       => '',  # For incomplete UTF-8 sequences
    }, $class;

    return $self;
}

=head1 METHODS

=head2 next_chunk

    my $chunk = await $stream->next_chunk;

Returns a Future that resolves to the next chunk of data, or undef when the
stream is exhausted or client disconnects.

If C<decode> was specified in the constructor, chunks are decoded to the
specified encoding. UTF-8 decoding properly handles incomplete multi-byte
sequences at chunk boundaries.

Throws an exception if C<max_bytes> is exceeded.

=cut

async sub next_chunk {
    my ($self) = @_;
    return undef if $self->{_done};
    return undef if $self->{_error};

    my $message = await $self->{receive}->();

    # Handle disconnect
    if (!$message || $message->{type} eq 'http.disconnect') {
        $self->{_done} = 1;
        # Flush any remaining buffered data from incomplete UTF-8 sequences
        if ($self->{decode} && length($self->{_buffer})) {
            my $final = $self->_decode_chunk('', 1);  # flush=1
            return $final if length($final);
        }
        return undef;
    }

    # Extract body chunk
    my $chunk = $message->{body} // '';
    my $more = $message->{more} // 0;

    # Check size limit before processing
    if (defined $self->{max_bytes}) {
        my $new_total = $self->{_bytes_read} + length($chunk);
        if ($new_total > $self->{max_bytes}) {
            $self->{_error} = "Request body $self->{limit_name} exceeded";
            $self->{_done} = 1;
            croak($self->{_error});
        }
    }

    $self->{_bytes_read} += length($chunk);

    # Mark done if no more chunks
    $self->{_done} = 1 unless $more;

    # Decode if requested
    if ($self->{decode}) {
        $chunk = $self->_decode_chunk($chunk, !$more);
    }

    return $chunk;
}

=head2 bytes_read

    my $total = $stream->bytes_read;

Returns the total number of raw bytes read so far (before any decoding).

=cut

sub bytes_read {
    my ($self) = @_;
    return $self->{_bytes_read};
}

=head2 is_done

    if ($stream->is_done) { ... }

Returns true if the stream has been exhausted (no more chunks available).

=cut

sub is_done {
    my ($self) = @_;
    return $self->{_done};
}

=head2 error

    my $error = $stream->error;

Returns any error that occurred during streaming, or undef.

=cut

sub error {
    my ($self) = @_;
    return $self->{_error};
}

=head2 stream_to_file

    await $stream->stream_to_file($path);

Streams the entire request body to a file. Returns a Future that resolves
to the number of bytes written.

This is efficient for large uploads as it doesn't load the entire body into
memory - chunks are written incrementally as they arrive from the network.

B<Note:> File writes are B<blocking> (synchronous I/O). Since chunks are
typically small (e.g., 64KB), each write completes quickly. The method
remains async overall because it awaits network chunks between writes.

B<Note:> Cannot be used with the C<decode> option as that would corrupt binary
data. Use C<stream_to()> with a custom handler if you need decoded chunks
written to a file.

For fully non-blocking file I/O, use C<stream_to()> with your preferred
async file library:

    # Non-blocking alternative (bring your own async file library)
    await $stream->stream_to(async sub {
        my ($chunk) = @_;
        await $my_async_file_writer->write($chunk);
    });

=cut

async sub stream_to_file {
    my ($self, $path) = @_;
    croak("path is required") unless defined $path;
    croak("stream_to_file() cannot be used with decode option - use stream_to() instead")
        if $self->{decode};

    my $bytes_written = 0;
    my $fh;

    while (!$self->is_done) {
        my $chunk = await $self->next_chunk;
        last unless defined $chunk;
        next unless length $chunk;

        # Open file on first chunk (truncate mode)
        unless ($fh) {
            open $fh, '>:raw', $path
                or croak("Cannot open $path for writing: $!");
        }

        # Blocking write - typically fast for small chunks
        print $fh $chunk
            or croak("Cannot write to $path: $!");

        $bytes_written += length($chunk);
    }

    # Close file if we opened it
    if ($fh) {
        close $fh
            or croak("Cannot close $path: $!");
    }

    return $bytes_written;
}

=head2 stream_to

    await $stream->stream_to(async sub ($chunk) {
        # Process chunk
    });

Streams the entire request body to a custom sink callback. The callback
receives each chunk and can be async (return a Future).

Returns a Future that resolves to the number of bytes processed.

=cut

async sub stream_to {
    my ($self, $callback) = @_;
    croak("callback is required") unless $callback;

    my $bytes_processed = 0;

    while (!$self->is_done) {
        my $chunk = await $self->next_chunk;
        last unless defined $chunk;
        next unless length $chunk;

        # Call callback - it may be async
        my $result = $callback->($chunk);
        if (ref($result) && $result->can('get')) {
            await $result;
        }

        $bytes_processed += length($chunk);
    }

    return $bytes_processed;
}

=head1 INTERNAL METHODS

=head2 _decode_chunk

Internal method to decode a chunk with proper handling of incomplete UTF-8
sequences at boundaries.

=cut

sub _decode_chunk {
    my ($self, $chunk, $flush) = @_;
    $flush //= 0;
    my $encoding = $self->{decode};
    return $chunk unless $encoding;

    # Combine with buffered incomplete sequence from previous chunk
    my $data = $self->{_buffer} . $chunk;

    # Use Encode::FB_QUIET for incremental decoding - the standard approach
    # recommended by Encode documentation for handling partial multi-byte sequences
    my $decoded = eval {
        if ($flush || !length($data)) {
            # Final chunk or empty - decode everything
            $self->{_buffer} = '';
            my $flag = $self->{strict} ? (Encode::FB_CROAK | Encode::LEAVE_SRC) : (Encode::FB_DEFAULT | Encode::LEAVE_SRC);
            return decode($encoding, $data, $flag);
        } else {
            # Incremental decoding with FB_QUIET
            # FB_QUIET modifies $data in place, removing the decoded portion
            # and leaving incomplete sequences in $data for next time
            my $result = decode($encoding, $data, Encode::FB_QUIET);

            # Whatever remains in $data is incomplete - buffer it
            $self->{_buffer} = $data;

            # In strict mode, check if buffered data is invalid (not just incomplete)
            if ($self->{strict} && length($self->{_buffer}) > 0) {
                my $test = $self->{_buffer};
                eval { decode($encoding, $test, Encode::FB_CROAK | Encode::LEAVE_SRC); };
                die $@ if $@;  # Propagate if invalid UTF-8
            }

            return $result;
        }
    };

    if ($@) {
        $self->{_error} = "Failed to decode chunk: $@";
        $self->{_done} = 1;
        croak($self->{_error});
    }

    return $decoded;
}

1;

__END__

=head1 EXAMPLES

=head2 Processing Large Uploads

    async sub upload_handler ($scope, $receive, $send) {
        my $stream = PAGI::Request::BodyStream->new(
            receive   => $receive,
            max_bytes => 100 * 1024 * 1024,  # 100MB limit
        );

        # Stream directly to file
        my $bytes = await $stream->stream_to_file('/uploads/data.bin');

        await $send->({
            type => 'http.response.start',
            status => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => "Uploaded $bytes bytes\n",
        });
    }

=head2 Line-by-Line Processing

    async sub process_csv ($scope, $receive, $send) {
        my $stream = PAGI::Request::BodyStream->new(
            receive => $receive,
            decode  => 'UTF-8',
        );

        my $line_buffer = '';
        my $line_count = 0;

        while (!$stream->is_done) {
            my $chunk = await $stream->next_chunk;
            last unless defined $chunk;

            $line_buffer .= $chunk;

            # Process complete lines
            while ($line_buffer =~ s/^(.*?)\n//) {
                my $line = $1;
                $line_count++;
                # Process $line...
            }
        }

        # Process final line if no trailing newline
        $line_count++ if length($line_buffer);

        # Send response...
    }

=head2 Custom Processing with Backpressure

    async sub hash_upload ($scope, $receive, $send) {
        use Digest::SHA;

        my $stream = PAGI::Request::BodyStream->new(receive => $receive);
        my $sha = Digest::SHA->new(256);

        my $bytes = await $stream->stream_to(async sub ($chunk) {
            $sha->add($chunk);

            # Simulate slow processing (backpressure)
            await some_slow_operation($chunk);
        });

        my $digest = $sha->hexdigest;

        # Send digest response...
    }

=head1 ERROR HANDLING

The stream throws exceptions in these cases:

=over 4

=item * C<max_bytes> exceeded - Request body too large

=item * UTF-8 decoding errors (when C<< strict => 1 >>)

=item * File I/O errors during C<stream_to_file>

=back

Always wrap stream operations in eval/try-catch:

    use Syntax::Keyword::Try;

    try {
        await $stream->stream_to_file($path);
    }
    catch ($e) {
        # Handle error
        await send_error($send, 400, "Upload failed: $e");
    }

=head1 SEE ALSO

L<PAGI::Request>, L<Future::AsyncAwait>

=head1 AUTHOR

PAGI Contributors

=cut

