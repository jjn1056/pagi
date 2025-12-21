package PAGI::Util::AsyncFile;

use strict;
use warnings;

our $VERSION = '0.01';

use Future;
use Future::AsyncAwait;
use IO::Async::Function;
use Scalar::Util qw(blessed);

=head1 NAME

PAGI::Util::AsyncFile - Non-blocking file I/O for PAGI applications

=head1 SYNOPSIS

    use PAGI::Util::AsyncFile;

    # Get the loop from PAGI scope
    my $loop = $scope->{pagi}{loop};

    # Read entire file
    my $content = await PAGI::Util::AsyncFile->read_file($loop, '/path/to/file');

    # Read file in chunks (streaming)
    await PAGI::Util::AsyncFile->read_file_chunked($loop, '/path/to/file', async sub  {
        my ($chunk) = @_;
        # Process each chunk
        await $send->({ type => 'http.response.body', body => $chunk, more => 1 });
    }, chunk_size => 65536);

    # Write file
    await PAGI::Util::AsyncFile->write_file($loop, '/path/to/file', $content);

    # Append to file
    await PAGI::Util::AsyncFile->append_file($loop, '/path/to/file', $log_line);

=head1 DESCRIPTION

This module provides non-blocking file I/O operations for use in PAGI async
applications. It uses L<IO::Async::Function> to offload blocking file operations
to worker processes, preventing the main event loop from being blocked during
disk I/O.

Regular file I/O in POSIX is always blocking at the kernel level - even
C<select()>/C<poll()>/C<epoll()> report regular files as always "ready".
This module works around this limitation by running file operations in
separate worker processes, similar to how Node.js/libuv handles file I/O.

=head1 CLASS METHODS

=cut

# Singleton function pool per loop (keyed by loop address)
my %_function_pools;

# Get or create the function pool for a given loop
sub _get_function {
    my ($class, $loop) = @_;

    my $loop_id = blessed($loop) ? "$loop" : 'default';

    unless ($_function_pools{$loop_id}) {
        my $function = IO::Async::Function->new(
            code => sub  {
        my ($op, @args) = @_;
                return _worker_operation($op, @args);
            },
            min_workers => 1,
            max_workers => 4,
            idle_timeout => 30,
        );

        $loop->add($function);
        $_function_pools{$loop_id} = $function;
    }

    return $_function_pools{$loop_id};
}

# Worker process operations
sub _worker_operation {
    my ($op, @args) = @_;

    if ($op eq 'read_file') {
        my ($path) = @args;
        open my $fh, '<:raw', $path or die "Cannot open $path: $!";
        local $/;
        my $content = <$fh>;
        close $fh;
        return $content;
    }
    elsif ($op eq 'read_chunk') {
        my ($path, $offset, $chunk_size) = @args;
        open my $fh, '<:raw', $path or die "Cannot open $path: $!";
        seek($fh, $offset, 0) if $offset;
        my $bytes_read = read($fh, my $buffer, $chunk_size);
        close $fh;
        return ($buffer, $bytes_read // 0);
    }
    elsif ($op eq 'write_file') {
        my ($path, $content) = @args;
        open my $fh, '>:raw', $path or die "Cannot open $path for writing: $!";
        print $fh $content;
        close $fh;
        return length($content);
    }
    elsif ($op eq 'append_file') {
        my ($path, $content) = @args;
        open my $fh, '>>:raw', $path or die "Cannot open $path for appending: $!";
        print $fh $content;
        close $fh;
        return length($content);
    }
    elsif ($op eq 'file_size') {
        my ($path) = @args;
        return -s $path;
    }
    elsif ($op eq 'file_exists') {
        my ($path) = @args;
        return -f $path ? 1 : 0;
    }
    else {
        die "Unknown operation: $op";
    }
}

=head2 read_file

    my $content = await PAGI::Util::AsyncFile->read_file($loop, $path);

Read the entire contents of a file asynchronously. Returns a Future that
resolves to the file contents.

Parameters:

=over 4

=item * C<$loop> - IO::Async::Loop instance

=item * C<$path> - Path to the file to read

=back

Throws an exception if the file cannot be read.

=cut

async sub read_file {
    my ($class, $loop, $path) = @_;

    die "File not found: $path" unless -f $path;
    die "Cannot read file: $path" unless -r $path;

    my $function = $class->_get_function($loop);
    return await $function->call(args => ['read_file', $path]);
}

=head2 read_file_chunked

    await PAGI::Util::AsyncFile->read_file_chunked($loop, $path, async sub  {
        my ($chunk) = @_;
        # Process chunk
    }, chunk_size => 65536);

    # For Range requests (partial file):
    await PAGI::Util::AsyncFile->read_file_chunked($loop, $path, $callback,
        offset => 1000,      # Start at byte 1000
        length => 5000,      # Read 5000 bytes total
    );

Read a file in chunks, calling a callback for each chunk. This is suitable
for streaming large files without loading the entire file into memory.

Parameters:

=over 4

=item * C<$loop> - IO::Async::Loop instance

=item * C<$path> - Path to the file to read

=item * C<$callback> - Async callback called with each chunk. Receives the chunk data.

=item * C<%opts> - Options:

=over 4

=item * C<chunk_size> - Size of each chunk in bytes (default: 65536)

=item * C<offset> - Byte offset to start reading from (default: 0)

=item * C<length> - Maximum bytes to read; omit to read to EOF

=back

=back

Returns a Future that resolves to the number of bytes read when complete.
The callback should return/await properly if it needs to do async operations.

=cut

async sub read_file_chunked {
    my ($class, $loop, $path, $callback, %opts) = @_;

    die "File not found: $path" unless -f $path;
    die "Cannot read file: $path" unless -r $path;

    my $chunk_size = $opts{chunk_size} // 65536;
    my $start_offset = $opts{offset} // 0;
    my $max_length = $opts{length};  # undef means read to EOF

    my $file_size = -s $path;
    my $function = $class->_get_function($loop);

    my $offset = $start_offset;
    my $bytes_sent = 0;

    # Calculate end position
    my $end_pos = defined $max_length
        ? $start_offset + $max_length
        : $file_size;
    $end_pos = $file_size if $end_pos > $file_size;

    while ($offset < $end_pos) {
        my $to_read = $chunk_size;

        # Don't read past the end position
        if ($offset + $to_read > $end_pos) {
            $to_read = $end_pos - $offset;
        }

        last if $to_read <= 0;

        my ($chunk, $bytes_read) = await $function->call(
            args => ['read_chunk', $path, $offset, $to_read]
        );

        last unless $bytes_read;

        # Call the callback - it may be async
        my $result = $callback->($chunk);
        if (blessed($result) && $result->can('get')) {
            await $result;
        }

        $offset += $bytes_read;
        $bytes_sent += $bytes_read;
    }

    return $bytes_sent;  # Return total bytes read
}

=head2 write_file

    await PAGI::Util::AsyncFile->write_file($loop, $path, $content);

Write content to a file asynchronously, replacing any existing content.

Parameters:

=over 4

=item * C<$loop> - IO::Async::Loop instance

=item * C<$path> - Path to the file to write

=item * C<$content> - Content to write

=back

Returns a Future that resolves to the number of bytes written.

=cut

async sub write_file {
    my ($class, $loop, $path, $content) = @_;

    my $function = $class->_get_function($loop);
    return await $function->call(args => ['write_file', $path, $content]);
}

=head2 append_file

    await PAGI::Util::AsyncFile->append_file($loop, $path, $content);

Append content to a file asynchronously.

Parameters:

=over 4

=item * C<$loop> - IO::Async::Loop instance

=item * C<$path> - Path to the file

=item * C<$content> - Content to append

=back

Returns a Future that resolves to the number of bytes written.

=cut

async sub append_file {
    my ($class, $loop, $path, $content) = @_;

    my $function = $class->_get_function($loop);
    return await $function->call(args => ['append_file', $path, $content]);
}

=head2 file_size

    my $size = await PAGI::Util::AsyncFile->file_size($loop, $path);

Get the size of a file asynchronously.

=cut

async sub file_size {
    my ($class, $loop, $path) = @_;

    my $function = $class->_get_function($loop);
    return await $function->call(args => ['file_size', $path]);
}

=head2 file_exists

    my $exists = await PAGI::Util::AsyncFile->file_exists($loop, $path);

Check if a file exists asynchronously.

=cut

async sub file_exists {
    my ($class, $loop, $path) = @_;

    my $function = $class->_get_function($loop);
    return await $function->call(args => ['file_exists', $path]);
}

=head2 cleanup

    PAGI::Util::AsyncFile->cleanup($loop);

Clean up the worker pool for a given loop. Call this during application
shutdown to properly terminate worker processes.

=cut

sub cleanup {
    my ($class, $loop) = @_;
    $loop //= undef;

    if ($loop) {
        my $loop_id = blessed($loop) ? "$loop" : 'default';
        if (my $function = delete $_function_pools{$loop_id}) {
            $loop->remove($function);
        }
    }
    else {
        # Clean up all pools
        for my $loop_id (keys %_function_pools) {
            my $function = delete $_function_pools{$loop_id};
            # Can't remove without loop reference, but clearing the hash helps
        }
    }
}

=head1 CONFIGURATION

The worker pool is configured with sensible defaults:

=over 4

=item * C<min_workers>: 1 - Minimum worker processes to keep alive

=item * C<max_workers>: 4 - Maximum concurrent worker processes

=item * C<idle_timeout>: 30 - Seconds before idle workers are shut down

=back

These settings balance responsiveness with resource usage. For applications
with heavy file I/O, you may want to adjust these values by modifying the
C<_get_function> method or by configuring at the application level.

=head1 THREAD SAFETY

Each IO::Async::Loop gets its own worker pool. Worker processes are forked
from the main process, so they inherit the initial state but operate
independently. File operations in workers do not affect the main process
state.

=head1 SEE ALSO

L<IO::Async::Function>, L<IO::Async::Loop>

=head1 AUTHOR

PAGI Contributors

=cut

1;
