use strict;
use warnings;
use Future::AsyncAwait;
use experimental 'signatures';
use JSON::PP (); # for pretty output (optional)

async sub drain_body ($receive) {
    while (1) {
        my $event = await $receive->();
        last if $event->{type} ne 'http.request';
        last unless $event->{more};
    }
}

async sub app ($scope, $receive, $send) {
    # Handle lifespan scope
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

    die "Unsupported scope type: $scope->{type}" unless $scope->{type} eq 'http';
    await drain_body($receive);

    my $tls = $scope->{extensions}{tls};
    my $body;
    if ($tls) {
        $body = "TLS info:\n" . JSON::PP->new->pretty(1)->encode({
            tls_version  => sprintf('0x%04x', $tls->{tls_version} // 0),
            cipher_suite => defined $tls->{cipher_suite} ? sprintf('0x%04x', $tls->{cipher_suite}) : undef,
            client_cert  => $tls->{client_cert_name},
        });
    }
    else {
        $body = "Connection is not using TLS";
    }

    await $send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [ [ 'content-type', 'text/plain' ] ],
    });

    await $send->({ type => 'http.response.body', body => $body, more => 0 });
}

\&app;
