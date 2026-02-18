package TestRoutes::Admin;

use strict;
use warnings;
use PAGI::App::Router;
use Future::AsyncAwait;

sub to_app {
    my $r = PAGI::App::Router->new;

    $r->get('/' => async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [['content-type', 'text/plain']] });
        await $send->({ type => 'http.response.body', body => 'admin_dashboard', more => 0 });
    });

    $r->get('/settings' => async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [['content-type', 'text/plain']] });
        await $send->({ type => 'http.response.body', body => 'admin_settings', more => 0 });
    });

    return $r->to_app;
}

1;
