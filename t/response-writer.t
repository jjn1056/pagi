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

done_testing;
