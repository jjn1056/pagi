use strict;
use warnings;
use utf8;
use Test2::V0;
use IO::Async::Loop;
use Net::Async::HTTP;
use Future::AsyncAwait;
use Encode qw(encode_utf8 decode_utf8);
use FindBin;
use lib "$FindBin::Bin/../lib";

use PAGI::Server;

my $loop = IO::Async::Loop->new;
my $sample = "λ🔥café";

sub percent_encode {
    my ($str) = @_;

    my $bytes = encode_utf8($str // '');
    $bytes =~ s/([^A-Za-z0-9\-._~])/sprintf("%%%02X", ord($1))/eg;
    return $bytes;
}

my %captures;

my $app = async sub  {
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

    if ($scope->{type} eq 'http') {
        my $body = '';
        while (1) {
            my $event = await $receive->();
            $body .= $event->{body} // '' if $event->{type} eq 'http.request';
            last unless $event->{more};
        }

        $captures{last_http} = {
            path         => $scope->{path},
            raw_path     => $scope->{raw_path},
            query_string => $scope->{query_string},
            body         => $body,
        };

        if ($scope->{path} =~ m{^/response-utf8$}) {
            my $bytes = encode_utf8($sample);
            await $send->({
                type    => 'http.response.start',
                status  => 200,
                headers => [
                    ['content-type', 'text/plain; charset=utf-8'],
                    ['content-length', length($bytes)],
                ],
            });
            await $send->({
                type => 'http.response.body',
                body => $bytes,
                more => 0,
            });
            return;
        }

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'ok',
            more => 0,
        });
        return;
    }

    if ($scope->{type} eq 'websocket') {
        $captures{last_ws_path} = $scope->{path};

        await $send->({ type => 'websocket.accept' });

        while (1) {
            my $event = await $receive->();
            if ($event->{type} eq 'websocket.receive' && defined $event->{text}) {
                await $send->({
                    type => 'websocket.send',
                    text => $event->{text},
                });
            }
            elsif ($event->{type} eq 'websocket.disconnect') {
                last;
            }
        }
        return;
    }

    die "Unhandled scope type: $scope->{type}";
};

sub create_server {
    my $server = PAGI::Server->new(
        app   => $app,
        host  => '127.0.0.1',
        port  => 0,
        quiet => 1,
    );

    $loop->add($server);
    $server->listen->get;

    return $server;
}

subtest 'HTTP path/query/body UTF-8 handling' => sub {
    my $server = create_server();
    my $port = $server->port;

    my $http = Net::Async::HTTP->new;
    $loop->add($http);

    my $encoded = percent_encode($sample);
    my $url = "http://127.0.0.1:$port/utf8/$encoded?text=$encoded";

    $http->POST(
        URI->new($url),
        "text=$encoded",
        content_type => 'application/x-www-form-urlencoded',
    )->get;

    is($captures{last_http}{path}, "/utf8/$sample", 'path decoded to characters');
    is($captures{last_http}{raw_path}, "/utf8/$encoded", 'raw_path preserved percent-encoding');
    is($captures{last_http}{query_string}, "text=$encoded", 'query_string preserved percent-encoding');
    is($captures{last_http}{body}, "text=$encoded", 'body preserved form-encoded bytes');

    $server->shutdown->get;
    $loop->remove($http);
};

subtest 'HTTP response encodes UTF-8 body' => sub {
    my $server = create_server();
    my $port = $server->port;

    my $http = Net::Async::HTTP->new;
    $loop->add($http);

    my $response = $http->GET("http://127.0.0.1:$port/response-utf8")->get;

    is($response->code, 200, 'status 200');
    is($response->header('content-type'), 'text/plain; charset=utf-8', 'content-type with charset');
    is($response->decoded_content, $sample, 'response body decoded to characters');

    $server->shutdown->get;
    $loop->remove($http);
};

subtest 'WebSocket UTF-8 path and message' => sub {
    eval {
        require Net::Async::WebSocket::Client;
        Net::Async::WebSocket::Client->import;
    } or do {
        plan skip_all => 'Net::Async::WebSocket::Client (meta.pm) not available';
    };

    my $server = create_server();
    my $port = $server->port;

    my $client = Net::Async::WebSocket::Client->new(
        on_text_frame => sub {
            my ($self, $text) = @_;
            $self->{received} = $text;
        },
    );
    $loop->add($client);

    my $encoded = percent_encode($sample);
    $client->connect(url => "ws://127.0.0.1:$port/ws/$encoded")->get;
    $client->send_text_frame($sample);

    my $deadline = time + 5;
    while (!defined $client->{received} && time < $deadline) {
        $loop->loop_once(0.1);
    }

    is($captures{last_ws_path}, "/ws/$sample", 'websocket path decoded to characters');
    is($client->{received}, $sample, 'websocket message echoed with UTF-8 intact');

    $client->close;
    $server->shutdown->get;
};

done_testing;
