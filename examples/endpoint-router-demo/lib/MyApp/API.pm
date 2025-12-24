package MyApp::API;
use parent 'PAGI::Endpoint::Router';
use strict;
use warnings;
use Future::AsyncAwait;

my @USERS = (
    { id => 1, name => 'Alice', email => 'alice@example.com' },
    { id => 2, name => 'Bob', email => 'bob@example.com' },
);

sub routes {
    my ($self, $r) = @_;

    $r->get('/info' => 'get_info');
    $r->get('/users' => 'list_users');
    $r->get('/users/:id' => 'get_user');
    $r->post('/users' => 'create_user');
}

async sub get_info {
    my ($self, $req, $res) = @_;
    $req->state->{metrics}{requests}++;

    my $config = $req->state->{config};

    await $res->json({
        app     => $config->{app_name},
        version => $config->{version},
        api     => 'v1',
    });
}

async sub list_users {
    my ($self, $req, $res) = @_;
    $req->state->{metrics}{requests}++;
    await $res->json(\@USERS);
}

async sub get_user {
    my ($self, $req, $res) = @_;
    $req->state->{metrics}{requests}++;

    my $id = $req->path_param('id');
    my ($user) = grep { $_->{id} == $id } @USERS;

    if ($user) {
        await $res->json($user);
    } else {
        await $res->status(404)->json({ error => 'User not found' });
    }
}

async sub create_user {
    my ($self, $req, $res) = @_;
    $req->state->{metrics}{requests}++;

    my $data = await $req->json;

    my $new_user = {
        id    => scalar(@USERS) + 1,
        name  => $data->{name},
        email => $data->{email},
    };
    push @USERS, $new_user;

    await $res->status(201)->json($new_user);
}

1;
