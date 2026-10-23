#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

# Runs PAGI::Cookbook's "Broadcasting events" recipe as published: the code
# block is taken from the POD, not copied here, so the test fails if the
# recipe does.

BEGIN {
    eval { require Future::IO; require IO::Async::Loop; 1 }
        or plan skip_all => 'Future::IO and IO::Async required';
}

use FindBin;
use Future::AsyncAwait;
use IO::Async::Loop;
use Future::IO::Impl::IOAsync;

my $loop = IO::Async::Loop->new;

sub recipe {
    my ($heading) = @_;
    open my $fh, '<', "$FindBin::Bin/../lib/PAGI/Cookbook.pod" or die "Cookbook.pod: $!";
    my $pod = do { local $/; <$fh> };
    my ($section) = $pod =~ /^=head2 \Q$heading\E\n(.*?)^=head/ms
        or die "no '$heading' section";
    my ($code) = $section =~ /^(    my \$app = async sub \{.*?^    \};)$/ms
        or die "no 'my \$app = async sub' block in '$heading'";
    my $app = eval "use Future::AsyncAwait; use Future::IO; $code; \$app" or die $@;
    return $app;
}

subtest 'Broadcasting events: a client that stays gets every event and the close' => sub {
    my $app = recipe('Broadcasting events');

    # A GET SSE request: the first receive is sse.request; after that the
    # client stays, so later receives wait.
    my @receives = ({ type => 'sse.request', body => '', more => 0 });
    my $receive = sub { @receives ? Future->done(shift @receives) : $loop->new_future };
    my @sent;
    my $send = async sub { push @sent, $_[0] };

    $loop->await($app->({ type => 'sse' }, $receive, $send));

    is([map { $_->{type} } @sent],
        ['sse.start', 'sse.send', 'sse.send', 'sse.send', 'sse.close'],
        'it starts the stream, sends the three events, and closes it');
    is([map { $_->{data} } grep { $_->{type} eq 'sse.send' } @sent], ['1', '2', 'finished'],
        'in order');
};

subtest 'Broadcasting events: a client that leaves gets no more events and no close' => sub {
    my $app = recipe('Broadcasting events');

    # The client leaves after the first event goes out.
    my $gone = $loop->new_future;
    my @receives = ({ type => 'sse.request', body => '', more => 0 });
    my $receive = sub { @receives ? Future->done(shift @receives) : $gone };
    my @sent;
    my $send = async sub {
        push @sent, $_[0];
        $gone->done({ type => 'sse.disconnect', reason => 'client_closed' })
            if $_[0]{type} eq 'sse.send' && !$gone->is_ready;
    };

    $loop->await($app->({ type => 'sse' }, $receive, $send));

    is([map { $_->{type} } @sent], ['sse.start', 'sse.send'],
        'one event, then nothing: no terminal event after the client left');
};

done_testing;
