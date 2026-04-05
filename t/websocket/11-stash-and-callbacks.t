#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';
use PAGI::WebSocket;
use PAGI::Stash;

# Helper to create connected WebSocket with message queue
# Each call creates a fresh scope to avoid singleton caching issues
sub create_ws {
    my (%opts) = @_;
    my @sent;
    my @messages = @{$opts{messages} // []};
    my $msg_idx = 0;

    my $send = sub {
        push @sent, $_[0];
        return Future->done;
    };

    # Fresh scope for each call (important for singleton caching)
    my $scope = { type => 'websocket', headers => [] };
    my $receive = sub {
        if ($msg_idx == 0) {
            $msg_idx++;
            return Future->done({ type => 'websocket.connect' });
        }
        if ($msg_idx <= @messages) {
            my $msg = $messages[$msg_idx - 1];
            $msg_idx++;
            return Future->done({
                type => 'websocket.receive',
                text => $msg,
            });
        }
        return Future->done({ type => 'websocket.disconnect' });
    };

    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    $ws->accept->get;

    return ($ws, \@sent);
}

subtest 'stash provides per-connection storage' => sub {
    my ($ws) = create_ws();
    my $stash = PAGI::Stash->new($ws);

    is(ref($stash->data), 'HASH', 'stash returns hashref');
    is($stash->data, {}, 'stash starts empty');

    $stash->set(user => 'alice', room => 'lobby');

    is($stash->get('user'), 'alice', 'can store user');
    is($stash->get('room'), 'lobby', 'can store room');
};

subtest 'stash persists across calls' => sub {
    my ($ws) = create_ws();
    my $stash = PAGI::Stash->new($ws);

    $stash->set(counter => 0);
    $stash->data->{counter}++;
    $stash->data->{counter}++;

    is($stash->get('counter'), 2, 'stash persists modifications');
};

subtest 'on_error registers error callback' => sub {
    my ($ws) = create_ws();
    my @errors;

    $ws->on_error(sub {
        my ($error) = @_;
        push @errors, $error;
    });

    $ws->_trigger_error("Test error 1");
    $ws->_trigger_error("Test error 2");

    is(scalar @errors, 2, 'error callback called twice');
    like($errors[0], qr/Test error 1/, 'first error captured');
    like($errors[1], qr/Test error 2/, 'second error captured');
};

subtest 'on_error multiple callbacks' => sub {
    my ($ws) = create_ws();
    my @log1;
    my @log2;

    $ws->on_error(sub { push @log1, $_[0] });
    $ws->on_error(sub { push @log2, $_[0] });

    $ws->_trigger_error("Shared error");

    is(scalar @log1, 1, 'first callback called');
    is(scalar @log2, 1, 'second callback called');
};

subtest 'on_error warns if no handlers' => sub {
    my ($ws) = create_ws();
    my @warnings;

    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    $ws->_trigger_error("Unhandled error");

    is(scalar @warnings, 1, 'warning emitted');
    like($warnings[0], qr/Unhandled error/, 'warning contains error');
};

subtest 'on_message registers message callback' => sub {
    my ($ws) = create_ws();
    my @received;

    $ws->on_message(sub {
        my ($data) = @_;
        push @received, $data;
    });

    is(scalar @{$ws->{_on_message}}, 1, 'callback registered');
};

subtest 'on() generic event registration' => sub {
    my ($ws) = create_ws();

    $ws->on(message => sub { });
    $ws->on(close => sub { });
    $ws->on(error => sub { });

    is(scalar @{$ws->{_on_message}}, 1, 'message callback registered');
    is(scalar @{$ws->{_on_close}}, 1, 'close callback registered');
    is(scalar @{$ws->{_on_error}}, 1, 'error callback registered');
};

subtest 'on() dies for unknown event' => sub {
    my ($ws) = create_ws();

    like(
        dies { $ws->on(unknown => sub { }) },
        qr/Unknown event type/,
        'dies for unknown event type'
    );
};

subtest 'on() returns $self for chaining' => sub {
    my ($ws) = create_ws();

    my $result = $ws->on(message => sub { });
    ok($result == $ws, 'returns self for chaining');

    # Chain test
    $ws->on(message => sub { })
       ->on(close => sub { })
       ->on(error => sub { });

    is(scalar @{$ws->{_on_message}}, 2, 'chained message callbacks');
};

subtest 'run() dispatches to message callbacks' => sub {
    my ($ws) = create_ws(messages => ['hello', 'world']);
    my @received;

    $ws->on_message(sub {
        my ($data) = @_;
        push @received, $data;
    });

    $ws->run->get;

    is(\@received, ['hello', 'world'], 'all messages dispatched');
};

subtest 'run() handles async callbacks' => sub {
    my ($ws) = create_ws(messages => ['async test']);
    my @received;

    $ws->on_message(async sub {
        my ($data) = @_;
        push @received, $data;
        return;
    });

    $ws->run->get;

    is(\@received, ['async test'], 'async callback executed');
};

subtest 'run() triggers error handlers on exception' => sub {
    my ($ws) = create_ws(messages => ['trigger error']);
    my @errors;

    $ws->on_message(sub {
        die "Callback explosion";
    });

    $ws->on_error(sub {
        my ($error) = @_;
        push @errors, $error;
    });

    $ws->run->get;

    is(scalar @errors, 1, 'error handler called');
    like($errors[0], qr/Callback explosion/, 'error message captured');
};

subtest 'run() calls multiple message callbacks' => sub {
    my ($ws) = create_ws(messages => ['multi']);
    my @log1;
    my @log2;

    $ws->on_message(sub { push @log1, $_[0] });
    $ws->on_message(sub { push @log2, $_[0] });

    $ws->run->get;

    is(\@log1, ['multi'], 'first callback received message');
    is(\@log2, ['multi'], 'second callback received message');
};

done_testing;
