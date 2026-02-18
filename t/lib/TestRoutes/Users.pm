package TestRoutes::Users;

use strict;
use warnings;
use PAGI::App::Router;
use Future::AsyncAwait;

sub router {
    my $r = PAGI::App::Router->new;

    $r->get('/' => async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [['content-type', 'text/plain']] });
        await $send->({ type => 'http.response.body', body => 'users_list', more => 0 });
    })->name('users.list');

    $r->get('/:id' => async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [['content-type', 'text/plain']] });
        await $send->({ type => 'http.response.body', body => 'user_detail', more => 0 });
    })->name('users.get');

    return $r;
}

1;
