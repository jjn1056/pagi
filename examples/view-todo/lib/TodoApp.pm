package TodoApp;

use strict;
use warnings;
use parent 'PAGI::Simple';
use experimental 'signatures';

sub init ($class) {
    return (
        name  => 'Todo App',
        share => 'htmx',
        views => {
            directory => './templates',
            roles     => ['PAGI::Simple::View::Role::Valiant'],
            preamble  => 'use experimental "signatures";',
        },
    );
}

sub routes ($class, $app, $r) {
    # Mount handlers
    $r->mount('/' => '::Todos');

    # SSE for live updates
    $app->sse('/todos/live' => sub ($sse) {
        $sse->send_event(event => 'connected', data => 'ok');
        $sse->subscribe('todos:changes' => sub ($msg) {
            $sse->send_event(event => 'refresh', data => $msg->{action} // 'update');
        });
    });
}

1;
