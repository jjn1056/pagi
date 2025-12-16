package TodoApp::Todos::Bulk;

use strict;
use warnings;
use parent 'PAGI::Simple::Handler';
use experimental 'signatures';
use Future::AsyncAwait;

sub routes ($class, $app, $r) {
    $r->post('/toggle-all' => '#toggle_all')->name('todos_toggle_all');
    $r->post('/clear'      => '#clear_completed')->name('todos_clear');
}

async sub toggle_all ($self, $c) {
    my $todos = $c->service('Todo');
    $todos->toggle_all;
    $c->hx_trigger('todosChanged');
    $c->render('todos/_list',
        todos  => [$todos->all],
        active => $todos->active_count,
        filter => 'home',
    );
}

async sub clear_completed ($self, $c) {
    my $todos = $c->service('Todo');
    $todos->clear_completed;
    $c->hx_trigger('todosChanged');
    $c->render('todos/_list',
        todos  => [$todos->all],
        active => $todos->active_count,
        filter => 'home',
    );
}

1;
