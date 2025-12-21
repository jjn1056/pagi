use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;
use File::Temp qw(tempfile tempdir);
use File::Spec;

# Test: PAGI::Util::AsyncFile - Non-blocking file I/O

use PAGI::Util::AsyncFile;

my $loop = IO::Async::Loop->new;

#---------------------------------------------------------------------------
# read_file tests
#---------------------------------------------------------------------------

subtest 'read_file - small file' => sub {
    my ($fh, $filename) = tempfile(UNLINK => 1);
    print $fh "Hello, World!";
    close $fh;

    my $content = PAGI::Util::AsyncFile->read_file($loop, $filename)->get;

    is($content, "Hello, World!", 'read small file correctly');
};

subtest 'read_file - binary content' => sub {
    my ($fh, $filename) = tempfile(UNLINK => 1);
    binmode($fh);
    my $binary = join('', map { chr($_) } 0..255);
    print $fh $binary;
    close $fh;

    my $content = PAGI::Util::AsyncFile->read_file($loop, $filename)->get;

    is(length($content), 256, 'read binary file - correct length');
    is($content, $binary, 'read binary file - correct content');
};

subtest 'read_file - large file' => sub {
    my ($fh, $filename) = tempfile(UNLINK => 1);
    my $data = "X" x (1024 * 100);  # 100KB
    print $fh $data;
    close $fh;

    my $content = PAGI::Util::AsyncFile->read_file($loop, $filename)->get;

    is(length($content), 1024 * 100, 'read large file - correct length');
};

subtest 'read_file - file not found' => sub {
    my $error;
    eval {
        PAGI::Util::AsyncFile->read_file($loop, '/nonexistent/file.txt')->get;
    };
    $error = $@;

    like($error, qr/not found/i, 'throws on missing file');
};

subtest 'read_file - empty file' => sub {
    my ($fh, $filename) = tempfile(UNLINK => 1);
    close $fh;  # Create empty file

    my $content = PAGI::Util::AsyncFile->read_file($loop, $filename)->get;

    is($content, '', 'read empty file correctly');
};

#---------------------------------------------------------------------------
# read_file_chunked tests
#---------------------------------------------------------------------------

subtest 'read_file_chunked - basic' => sub {
    my ($fh, $filename) = tempfile(UNLINK => 1);
    print $fh "AAAA" x 100;  # 400 bytes
    close $fh;

    my @chunks;
    my $total = PAGI::Util::AsyncFile->read_file_chunked(
        $loop, $filename,
        sub  {
        my ($chunk) = @_; push @chunks, $chunk },
        chunk_size => 100
    )->get;

    is($total, 400, 'total bytes read correct');
    is(scalar(@chunks), 4, 'correct number of chunks');
    is(length($chunks[0]), 100, 'first chunk correct size');
};

subtest 'read_file_chunked - async callback' => sub {
    my ($fh, $filename) = tempfile(UNLINK => 1);
    print $fh "BBBB" x 50;  # 200 bytes
    close $fh;

    my @chunks;
    my $callback_count = 0;
    PAGI::Util::AsyncFile->read_file_chunked(
        $loop, $filename,
        async sub  {
        my ($chunk) = @_;
            $callback_count++;
            push @chunks, $chunk;
            # Simulate async processing
            await $loop->delay_future(after => 0.01);
        },
        chunk_size => 50
    )->get;

    is($callback_count, 4, 'async callback called correct times');
    is(join('', @chunks), "BBBB" x 50, 'all data received');
};

subtest 'read_file_chunked - single chunk' => sub {
    my ($fh, $filename) = tempfile(UNLINK => 1);
    print $fh "small";
    close $fh;

    my @chunks;
    PAGI::Util::AsyncFile->read_file_chunked(
        $loop, $filename,
        sub  {
        my ($chunk) = @_; push @chunks, $chunk },
        chunk_size => 1000  # Larger than file
    )->get;

    is(scalar(@chunks), 1, 'single chunk for small file');
    is($chunks[0], 'small', 'content correct');
};

#---------------------------------------------------------------------------
# write_file tests
#---------------------------------------------------------------------------

subtest 'write_file - basic' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $filename = File::Spec->catfile($dir, 'test.txt');

    my $bytes = PAGI::Util::AsyncFile->write_file($loop, $filename, "Hello, World!")->get;

    is($bytes, 13, 'returned correct byte count');
    ok(-f $filename, 'file created');

    open my $fh, '<', $filename;
    my $content = do { local $/; <$fh> };
    close $fh;

    is($content, "Hello, World!", 'file content correct');
};

subtest 'write_file - overwrite existing' => sub {
    my ($fh, $filename) = tempfile(UNLINK => 1);
    print $fh "original content";
    close $fh;

    PAGI::Util::AsyncFile->write_file($loop, $filename, "new content")->get;

    open $fh, '<', $filename;
    my $content = do { local $/; <$fh> };
    close $fh;

    is($content, "new content", 'file overwritten correctly');
};

subtest 'write_file - binary content' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $filename = File::Spec->catfile($dir, 'binary.bin');

    my $binary = join('', map { chr($_) } 0..255);
    PAGI::Util::AsyncFile->write_file($loop, $filename, $binary)->get;

    open my $fh, '<:raw', $filename;
    my $content = do { local $/; <$fh> };
    close $fh;

    is(length($content), 256, 'binary file correct length');
    is($content, $binary, 'binary content preserved');
};

#---------------------------------------------------------------------------
# append_file tests
#---------------------------------------------------------------------------

subtest 'append_file - to existing' => sub {
    my ($fh, $filename) = tempfile(UNLINK => 1);
    print $fh "Line 1\n";
    close $fh;

    PAGI::Util::AsyncFile->append_file($loop, $filename, "Line 2\n")->get;

    open $fh, '<', $filename;
    my $content = do { local $/; <$fh> };
    close $fh;

    is($content, "Line 1\nLine 2\n", 'append worked');
};

subtest 'append_file - multiple appends' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $filename = File::Spec->catfile($dir, 'log.txt');

    (async sub {
        await PAGI::Util::AsyncFile->append_file($loop, $filename, "Entry 1\n");
        await PAGI::Util::AsyncFile->append_file($loop, $filename, "Entry 2\n");
        await PAGI::Util::AsyncFile->append_file($loop, $filename, "Entry 3\n");
    })->()->get;

    open my $fh, '<', $filename;
    my $content = do { local $/; <$fh> };
    close $fh;

    is($content, "Entry 1\nEntry 2\nEntry 3\n", 'multiple appends worked');
};

#---------------------------------------------------------------------------
# file_size tests
#---------------------------------------------------------------------------

subtest 'file_size - basic' => sub {
    my ($fh, $filename) = tempfile(UNLINK => 1);
    print $fh "X" x 1234;
    close $fh;

    my $size = PAGI::Util::AsyncFile->file_size($loop, $filename)->get;

    is($size, 1234, 'file size correct');
};

#---------------------------------------------------------------------------
# file_exists tests
#---------------------------------------------------------------------------

subtest 'file_exists - existing file' => sub {
    my ($fh, $filename) = tempfile(UNLINK => 1);
    close $fh;

    my $exists = PAGI::Util::AsyncFile->file_exists($loop, $filename)->get;

    ok($exists, 'existing file returns true');
};

subtest 'file_exists - nonexistent file' => sub {
    my $exists = PAGI::Util::AsyncFile->file_exists($loop, '/nonexistent/file.txt')->get;

    ok(!$exists, 'nonexistent file returns false');
};

#---------------------------------------------------------------------------
# Concurrent operation tests
#---------------------------------------------------------------------------

subtest 'concurrent reads - non-blocking' => sub {
    # Create multiple files
    my @files;
    for my $i (1..5) {
        my ($fh, $filename) = tempfile(UNLINK => 1);
        print $fh "File $i content " x 100;
        close $fh;
        push @files, $filename;
    }

    my @results;

    (async sub {
        # Start all reads concurrently
        my @futures = map {
            my $file = $_;
            PAGI::Util::AsyncFile->read_file($loop, $file);
        } @files;

        # Wait for all to complete
        @results = await Future->wait_all(@futures);
    })->()->get;

    is(scalar(@results), 5, 'all concurrent reads completed');
    for my $i (0..$#results) {
        ok($results[$i]->is_done, "read $i completed successfully");
        like($results[$i]->get, qr/File/, "read $i has correct content");
    }
};

subtest 'concurrent read and write' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $read_file = File::Spec->catfile($dir, 'read.txt');
    my $write_file = File::Spec->catfile($dir, 'write.txt');

    # Create file to read
    open my $fh, '>', $read_file;
    print $fh "read this";
    close $fh;

    my ($read_content, $write_bytes);

    (async sub {
        # Do read and write concurrently
        my @futures = (
            PAGI::Util::AsyncFile->read_file($loop, $read_file),
            PAGI::Util::AsyncFile->write_file($loop, $write_file, "write this"),
        );

        my @results = await Future->wait_all(@futures);
        $read_content = $results[0]->get;
        $write_bytes = $results[1]->get;
    })->()->get;

    is($read_content, "read this", 'read completed during concurrent write');
    is($write_bytes, 10, 'write completed during concurrent read');
    ok(-f $write_file, 'write file created');
};

#---------------------------------------------------------------------------
# Error handling tests
#---------------------------------------------------------------------------

subtest 'write_file - permission denied' => sub {
    plan skip_all => 'Running as root' if $> == 0;

    my $error;
    eval {
        PAGI::Util::AsyncFile->write_file($loop, '/etc/shadow.test', 'test')->get;
    };
    $error = $@;

    like($error, qr/Cannot open|Permission denied/i, 'throws on permission denied');
};

#---------------------------------------------------------------------------
# Cleanup test
#---------------------------------------------------------------------------

subtest 'cleanup' => sub {
    # Just verify it doesn't crash
    ok(lives { PAGI::Util::AsyncFile->cleanup($loop) }, 'cleanup does not crash');
};

done_testing;
