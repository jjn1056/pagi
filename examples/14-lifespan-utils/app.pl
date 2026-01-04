use Future::AsyncAwait;
use PAGI::Utils qw(handle_lifespan);

use warnings;
use strict;

async sub pagi {
    my ( $scope, $receive, $send ) = @_;

    # Handle lifespan events
    return await handle_lifespan(
        $scope, $receive, $send,
        startup  => async sub { my ( $state ) = @_; warn 'doing startup'  },
        shutdown => async sub { my ( $state ) = @_; warn 'doing shutdown' },
    ) if $scope->{type} eq 'lifespan';

    # Rest of app (example)
    die "Unsupported scope type: $scope->{type}" unless $scope->{type} eq 'http';

    await $send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [
            [ 'content-type', 'text/plain' ],
        ],
    });

    await $send->({
        type => 'http.response.body',
        body => 'Hello from PAGI!',
        more => 0,
    });
}

\&pagi;
