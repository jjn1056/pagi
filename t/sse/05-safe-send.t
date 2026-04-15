#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';
use PAGI::SSE;

subtest 'try_send returns true on success' => sub {
    my $send = sub { Future->done };
    my $sse = PAGI::SSE->new({ type => 'sse' }, sub {}, $send);
    $sse->start->get;

    my $result = $sse->try_send("Hello")->get;
    ok($result, 'try_send returns true on success');
};

subtest 'try_send returns false when closed' => sub {
    my $sse = PAGI::SSE->new({ type => 'sse' }, sub {}, sub { Future->done });
    $sse->_set_closed;

    my $result = $sse->try_send("Hello")->get;
    ok(!$result, 'try_send returns false when closed');
};

subtest 'try_send returns false on send error' => sub {
    my $send = sub { Future->fail("Connection lost") };
    my $sse = PAGI::SSE->new({ type => 'sse' }, sub {}, $send);
    # Mark as started to avoid auto-start
    $sse->_set_state('started');

    # No on_error registered; suppress expected fallback warn
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    my $result = $sse->try_send("Hello")->get;
    ok(!$result, 'try_send returns false on error');
    ok($sse->is_closed, 'connection marked as closed after error');
    ok scalar @warnings, 'unhandled error produced warning';
};

subtest 'try_send_json works' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $sse = PAGI::SSE->new({ type => 'sse' }, sub {}, $send);
    $sse->start->get;

    my $result = $sse->try_send_json({ foo => 'bar' })->get;
    ok($result, 'try_send_json returns true');
    like($sent[1]{data}, qr/"foo"/, 'JSON was sent');
};

subtest 'try_send_event works' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $sse = PAGI::SSE->new({ type => 'sse' }, sub {}, $send);
    $sse->start->get;

    my $result = $sse->try_send_event(
        data  => 'test',
        event => 'ping',
    )->get;

    ok($result, 'try_send_event returns true');
    is($sent[1]{event}, 'ping', 'event name sent');
};

subtest 'on_error fires when try_send fails' => sub {
    my $send = sub { Future->fail("Connection lost") };
    my $sse = PAGI::SSE->new({ type => 'sse' }, sub {}, $send);
    $sse->_set_state('started');

    my ($fired_sse, $fired_err);
    $sse->on_error(sub {
        ($fired_sse, $fired_err) = @_;
    });

    $sse->try_send("Hello")->get;

    ok $fired_sse == $sse,        'on_error callback received $sse as first arg';
    like $fired_err, qr/Connection lost/, 'on_error callback received error';
};

subtest 'exception in on_error callback does not prevent others' => sub {
    my $send = sub { Future->fail("oops") };
    my $sse = PAGI::SSE->new({ type => 'sse' }, sub {}, $send);
    $sse->_set_state('started');

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    my $second_ran = 0;
    $sse->on_error(sub { die "first callback exploded\n" });
    $sse->on_error(sub { $second_ran = 1 });

    $sse->try_send("Hello")->get;

    ok $second_ran, 'second on_error callback ran despite first dying';
    ok scalar @warnings, 'exception in first on_error was warned';
    like $warnings[0], qr/first callback exploded/, 'warning contains error text';
};

subtest 'async on_error callback is awaited' => sub {
    my $send = sub { Future->fail("network error") };
    my $sse = PAGI::SSE->new({ type => 'sse' }, sub {}, $send);
    $sse->_set_state('started');

    my @fired;
    $sse->on_error(async sub { push @fired, 'async-ran' });

    $sse->try_send("Hello")->get;

    is \@fired, ['async-ran'], 'async on_error callback was awaited';
};

subtest 'async on_error exception does not prevent other callbacks' => sub {
    my $send = sub { Future->fail("network") };
    my $sse = PAGI::SSE->new({ type => 'sse' }, sub {}, $send);
    $sse->_set_state('started');

    my @fired;
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    $sse->on_error(async sub { die "async error handler exploded\n" });
    $sse->on_error(sub { push @fired, 'second' });

    $sse->try_send("Hello")->get;

    is \@fired, ['second'], 'second on_error ran despite async first dying';
    ok scalar @warnings, 'async exception in on_error was warned';
    like $warnings[0], qr/async error handler exploded/, 'warning contains error text';
};

subtest 'no on_error registered warns to STDERR' => sub {
    my $send = sub { Future->fail("send failure") };
    my $sse = PAGI::SSE->new({ type => 'sse' }, sub {}, $send);
    $sse->_set_state('started');

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    $sse->try_send("Hello")->get;

    ok scalar @warnings, 'unhandled error was warned';
    like $warnings[0], qr/send failure/, 'warning contains error text';
};

done_testing;
