use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use Future::AsyncAwait;

use PAGI::Server;

my $loop = IO::Async::Loop->new;

# Simple test app
my $app = async sub {
    my ($scope, $receive, $send) = @_;

    if ($scope->{type} eq 'lifespan') {
        while (1) {
            my $event = await $receive->();
            if ($event->{type} eq 'lifespan.startup') {
                await $send->({ type => 'lifespan.startup.complete' });
            }
            elsif ($event->{type} eq 'lifespan.shutdown') {
                await $send->({ type => 'lifespan.shutdown.complete' });
                last;
            }
        }
        return;
    }

    await $send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [['content-type', 'text/plain']],
    });
    await $send->({
        type => 'http.response.body',
        body => 'OK',
    });
};

subtest 'has_tls class method exists' => sub {
    ok(PAGI::Server->can('has_tls'), 'PAGI::Server has has_tls method');
    my $result = PAGI::Server->has_tls;
    ok(defined $result, 'has_tls returns defined value');
    ok($result == 0 || $result == 1, 'has_tls returns 0 or 1');
};

subtest 'disable_tls prevents TLS even with ssl config' => sub {
    # With disable_tls, construction should succeed — ssl config is stored but not applied
    my $server = eval {
        PAGI::Server->new(
            app         => $app,
            host        => '127.0.0.1',
            port        => 0,
            quiet       => 1,
            disable_tls => 1,
            ssl         => {
                cert_file => '/nonexistent/cert.pem',
                key_file  => '/nonexistent/key.pem',
            },
        );
    };

    ok !$@, 'disable_tls with ssl does not die' or diag $@;
    ok defined $server, 'server object created with disable_tls + ssl';
};

subtest 'server without TLS starts normally' => sub {
    my $server = PAGI::Server->new(
        app   => $app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
        # No ssl config
    );

    $loop->add($server);
    $server->listen->get;

    ok($server->is_running, 'Server without TLS starts normally');

    $server->shutdown->get;
    $loop->remove($server);
};

done_testing;
