#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use lib 'lib';
use PAGI::Request::MultiPartHandler;
use Future::AsyncAwait;

# Helper to create a mock receive that returns multipart data
sub mock_receive {
    my ($body) = @_;
    my $sent = 0;
    return sub {
        if (!$sent) {
            $sent = 1;
            return Future->done({
                type => 'http.request',
                body => $body,
                more => 0,
            });
        }
        return Future->done({ type => 'http.disconnect' });
    };
}

# Build a multipart body
sub build_multipart {
    my ($boundary, @parts) = @_;
    my $body = '';
    for my $part (@parts) {
        $body .= "--$boundary\r\n";
        if ($part->{filename}) {
            $body .= "Content-Disposition: form-data; name=\"$part->{name}\"; filename=\"$part->{filename}\"\r\n";
            $body .= "Content-Type: $part->{content_type}\r\n" if $part->{content_type};
        } else {
            $body .= "Content-Disposition: form-data; name=\"$part->{name}\"\r\n";
        }
        $body .= "\r\n";
        $body .= $part->{data};
        $body .= "\r\n";
    }
    $body .= "--$boundary--\r\n";
    return $body;
}

subtest 'form field within max_part_size limit' => sub {
    my $boundary = 'test-boundary-123';
    my $body = build_multipart($boundary, {
        name => 'field1',
        data => 'x' x 100,  # 100 bytes, well under 1MB default
    });

    my $handler = PAGI::Request::MultiPartHandler->new(
        boundary => $boundary,
        receive  => mock_receive($body),
    );

    my ($form, $uploads) = $handler->parse->get;
    is($form->get('field1'), 'x' x 100, 'form field parsed successfully');
};

subtest 'form field exceeds max_part_size' => sub {
    my $boundary = 'test-boundary-123';
    my $body = build_multipart($boundary, {
        name => 'field1',
        data => 'x' x 200,  # 200 bytes
    });

    my $handler = PAGI::Request::MultiPartHandler->new(
        boundary      => $boundary,
        receive       => mock_receive($body),
        max_part_size => 100,  # Only allow 100 bytes for form fields
    );

    like(
        dies { $handler->parse->get },
        qr/Form field too large/,
        'form field rejected when exceeding max_part_size'
    );
};

subtest 'file upload within max_upload_size limit' => sub {
    my $boundary = 'test-boundary-123';
    my $body = build_multipart($boundary, {
        name         => 'file1',
        filename     => 'test.txt',
        content_type => 'text/plain',
        data         => 'x' x 500,  # 500 bytes
    });

    my $handler = PAGI::Request::MultiPartHandler->new(
        boundary        => $boundary,
        receive         => mock_receive($body),
        max_upload_size => 1000,  # Allow 1000 bytes for uploads
    );

    my ($form, $uploads) = $handler->parse->get;
    my $upload = $uploads->get('file1');
    ok($upload, 'file upload parsed successfully');
    is($upload->filename, 'test.txt', 'filename correct');
};

subtest 'file upload exceeds max_upload_size' => sub {
    my $boundary = 'test-boundary-123';
    my $body = build_multipart($boundary, {
        name         => 'file1',
        filename     => 'test.txt',
        content_type => 'text/plain',
        data         => 'x' x 500,  # 500 bytes
    });

    my $handler = PAGI::Request::MultiPartHandler->new(
        boundary        => $boundary,
        receive         => mock_receive($body),
        max_upload_size => 100,  # Only allow 100 bytes for uploads
    );

    like(
        dies { $handler->parse->get },
        qr/File upload too large/,
        'file upload rejected when exceeding max_upload_size'
    );
};

subtest 'different limits for fields vs uploads' => sub {
    my $boundary = 'test-boundary-123';
    # Form field: 50 bytes (under 100 byte limit)
    # File upload: 500 bytes (under 1000 byte limit, but over 100 byte field limit)
    my $body = build_multipart($boundary,
        {
            name => 'field1',
            data => 'x' x 50,
        },
        {
            name         => 'file1',
            filename     => 'test.txt',
            content_type => 'text/plain',
            data         => 'x' x 500,
        },
    );

    my $handler = PAGI::Request::MultiPartHandler->new(
        boundary        => $boundary,
        receive         => mock_receive($body),
        max_part_size   => 100,   # 100 bytes for form fields
        max_upload_size => 1000,  # 1000 bytes for file uploads
    );

    my ($form, $uploads) = $handler->parse->get;
    is($form->get('field1'), 'x' x 50, 'form field parsed');
    ok($uploads->get('file1'), 'file upload parsed');
    is($uploads->get('file1')->size, 500, 'file size correct');
};

subtest 'file upload uses upload limit not part limit' => sub {
    my $boundary = 'test-boundary-123';
    # File of 500 bytes should pass with max_upload_size=1000
    # even though max_part_size=100
    my $body = build_multipart($boundary, {
        name         => 'file1',
        filename     => 'big.bin',
        content_type => 'application/octet-stream',
        data         => 'x' x 500,
    });

    my $handler = PAGI::Request::MultiPartHandler->new(
        boundary        => $boundary,
        receive         => mock_receive($body),
        max_part_size   => 100,   # Would fail if applied to files
        max_upload_size => 1000,  # Should use this for files
    );

    my ($form, $uploads) = $handler->parse->get;
    ok($uploads->get('file1'), 'large file accepted using max_upload_size');
};

done_testing;
