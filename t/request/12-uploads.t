#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;

use lib 'lib';
use PAGI::Request;

sub build_multipart {
    my ($boundary, @parts) = @_;
    my $body = '';
    for my $part (@parts) {
        $body .= "--$boundary\r\n";
        $body .= "Content-Disposition: form-data; name=\"$part->{name}\"";
        if ($part->{filename}) {
            $body .= "; filename=\"$part->{filename}\"";
        }
        $body .= "\r\n";
        if ($part->{content_type}) {
            $body .= "Content-Type: $part->{content_type}\r\n";
        }
        $body .= "\r\n";
        $body .= $part->{data};
        $body .= "\r\n";
    }
    $body .= "--$boundary--\r\n";
    return $body;
}

sub mock_receive {
    my ($body) = @_;
    my $sent = 0;
    return async sub {
        if (!$sent) {
            $sent = 1;
            return { type => 'http.request', body => $body, more => 0 };
        }
        return { type => 'http.disconnect' };
    };
}

subtest 'uploads() returns Hash::MultiValue of Upload objects' => sub {
    my $boundary = '----Test';
    my $body = build_multipart($boundary,
        { name => 'title', data => 'My Document' },
        { name => 'file', filename => 'doc.pdf', content_type => 'application/pdf', data => 'PDF data' },
    );

    my $scope = {
        type    => 'http',
        method  => 'POST',
        headers => [['content-type', "multipart/form-data; boundary=$boundary"]],
    };
    my $receive = mock_receive($body);
    my $req = PAGI::Request->new($scope, $receive);

    my $uploads = (async sub { await $req->uploads })->()->get;

    isa_ok($uploads, ['Hash::MultiValue']);
    my $file = $uploads->get('file');
    isa_ok($file, ['PAGI::Request::Upload']);
    is($file->filename, 'doc.pdf');
};

subtest 'upload() shortcut for single file' => sub {
    my $boundary = '----Test';
    my $body = build_multipart($boundary,
        { name => 'avatar', filename => 'me.jpg', content_type => 'image/jpeg', data => 'JPEG' },
    );

    my $scope = {
        type    => 'http',
        method  => 'POST',
        headers => [['content-type', "multipart/form-data; boundary=$boundary"]],
    };
    my $receive = mock_receive($body);
    my $req = PAGI::Request->new($scope, $receive);

    my $avatar = (async sub { await $req->upload('avatar') })->()->get;

    isa_ok($avatar, ['PAGI::Request::Upload']);
    is($avatar->filename, 'me.jpg');

    my $missing = (async sub { await $req->upload('nonexistent') })->()->get;
    is($missing, undef, 'missing upload returns undef');
};

subtest 'form_params() works with multipart' => sub {
    my $boundary = '----Test';
    my $body = build_multipart($boundary,
        { name => 'name', data => 'John' },
        { name => 'email', data => 'john@example.com' },
        { name => 'photo', filename => 'pic.jpg', content_type => 'image/jpeg', data => 'IMG' },
    );

    my $scope = {
        type    => 'http',
        method  => 'POST',
        headers => [['content-type', "multipart/form-data; boundary=$boundary"]],
    };
    my $receive = mock_receive($body);
    my $req = PAGI::Request->new($scope, $receive);

    my $form = (async sub { await $req->form_params })->()->get;

    is($form->get('name'), 'John', 'form field from multipart');
    is($form->get('email'), 'john@example.com', 'another form field');
    is($form->get('photo'), undef, 'file not in form');
};

subtest 'upload_all() for multiple files' => sub {
    my $boundary = '----Test';
    my $body = build_multipart($boundary,
        { name => 'docs', filename => 'a.pdf', content_type => 'application/pdf', data => 'A' },
        { name => 'docs', filename => 'b.pdf', content_type => 'application/pdf', data => 'B' },
        { name => 'docs', filename => 'c.pdf', content_type => 'application/pdf', data => 'C' },
    );

    my $scope = {
        type    => 'http',
        method  => 'POST',
        headers => [['content-type', "multipart/form-data; boundary=$boundary"]],
    };
    my $receive = mock_receive($body);
    my $req = PAGI::Request->new($scope, $receive);

    my @docs = (async sub { await $req->upload_all('docs') })->()->get;

    is(scalar(@docs), 3, 'three uploads');
    is($docs[0]->filename, 'a.pdf');
    is($docs[1]->filename, 'b.pdf');
    is($docs[2]->filename, 'c.pdf');
};

done_testing;
