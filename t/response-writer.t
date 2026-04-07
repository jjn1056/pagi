use strict;
use warnings;

use Test2::V0;
use Future::AsyncAwait;

use PAGI::Response;

# Helper: create a Response with a capturing $send
sub make_response {
    my @sent;
    my $send = sub { my ($msg) = @_; push @sent, $msg; Future->done };
    my $res = PAGI::Response->new({}, $send);
    return ($res, \@sent);
}

subtest 'on_close callbacks fire when writer closes' => sub {
    my ($res, $sent) = make_response();
    my @fired;

    $res->stream(async sub {
        my ($writer) = @_;
        $writer->on_close(sub { push @fired, 'first' });
        $writer->on_close(sub { push @fired, 'second' });
        await $writer->write("data");
        await $writer->close;
    })->get;

    is \@fired, ['first', 'second'], 'on_close callbacks fire in registration order';
};

subtest 'on_close via constructor' => sub {
    my ($res, $sent) = make_response();
    my @fired;

    $res->stream(async sub {
        my ($writer) = @_;
        $writer->on_close(sub { push @fired, 'cleanup' });
        await $writer->write("data");
        await $writer->close;
    })->get;

    is \@fired, ['cleanup'], 'on_close registered early still fires';
};

subtest 'is_closed returns correct state' => sub {
    my ($res, $sent) = make_response();

    $res->stream(async sub {
        my ($writer) = @_;
        is $writer->is_closed, 0, 'not closed initially';
        await $writer->write("data");
        is $writer->is_closed, 0, 'not closed after write';
        await $writer->close;
        is $writer->is_closed, 1, 'closed after close';
    })->get;
};

subtest 'write after close returns failed Future' => sub {
    my ($res, $sent) = make_response();

    $res->stream(async sub {
        my ($writer) = @_;
        await $writer->write("data");
        await $writer->close;

        my $f = $writer->write("after close");
        ok $f->is_failed, 'write after close returns failed Future';
        like [$f->failure]->[0], qr/closed/i, 'failure message mentions closed';
    })->get;
};

subtest 'write after close does not send events' => sub {
    my ($res, $sent) = make_response();

    $res->stream(async sub {
        my ($writer) = @_;
        await $writer->write("data");
        await $writer->close;

        # Capture count before bad write
        my $count = scalar @$sent;
        $writer->write("should not send");  # don't await — it's failed
        is scalar @$sent, $count, 'no new events sent after close';
    })->get;
};

subtest 'writer() returns a Writer and sends headers' => sub {
    my ($res, $sent) = make_response();

    $res->content_type('text/plain')->status(200);

    my $writer = $res->writer->get;

    isa_ok $writer, 'PAGI::Response::Writer';

    # Headers should already be sent
    is scalar @$sent, 1, 'http.response.start sent';
    is $sent->[0]{type}, 'http.response.start', 'start event sent';
    is $sent->[0]{status}, 200, 'status correct';

    # Write and close
    $writer->write("hello")->get;
    $writer->close->get;

    is $sent->[1]{body}, 'hello', 'chunk sent';
    is $sent->[1]{more}, 1, 'more=1 for chunk';
    is $sent->[2]{more}, 0, 'more=0 for close';
};

subtest 'writer() with on_close option' => sub {
    my ($res, $sent) = make_response();
    my @fired;

    my $writer = $res->writer(on_close => sub { push @fired, 'init' })->get;

    $writer->on_close(sub { push @fired, 'later' });

    $writer->write("data")->get;
    $writer->close->get;

    is \@fired, ['init', 'later'], 'constructor on_close fires first, then added ones';
};

subtest 'writer() prevents double send' => sub {
    my ($res, $sent) = make_response();

    $res->writer->get;

    like dies { $res->writer->get }, qr/already sent/i, 'second writer() croaks';
};

subtest 'writer() chains with response methods' => sub {
    my ($res, $sent) = make_response();

    my $writer = $res
        ->status(201)
        ->content_type('application/x-ndjson')
        ->header('X-Stream' => 'true')
        ->writer
        ->get;

    is $sent->[0]{status}, 201, 'status from chain';
    my %headers = map { $_->[0] => $_->[1] } @{$sent->[0]{headers}};
    is $headers{'content-type'}, 'application/x-ndjson', 'content-type from chain';
    is $headers{'X-Stream'}, 'true', 'custom header from chain';
};

subtest 'on_close fires on stream() auto-close' => sub {
    my ($res, $sent) = make_response();
    my @fired;

    $res->stream(async sub {
        my ($writer) = @_;
        $writer->on_close(sub { push @fired, 'auto' });
        await $writer->write("data");
        # Do NOT call $writer->close — let stream() auto-close
    })->get;

    is \@fired, ['auto'], 'on_close fires when stream() auto-closes writer';
};

subtest 'on_close fires only once even with explicit + auto close' => sub {
    my ($res, $sent) = make_response();
    my $count = 0;

    $res->stream(async sub {
        my ($writer) = @_;
        $writer->on_close(sub { $count++ });
        await $writer->write("data");
        await $writer->close;
        # stream() will also try to close, but close() is idempotent
    })->get;

    is $count, 1, 'on_close fires exactly once (close is idempotent)';
};

done_testing;
