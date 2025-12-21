package Test::PAGI::Server;
use strict;
use warnings;

our $VERSION = '0.001';

=head1 NAME

Test::PAGI::Server - Test utilities for PAGI::Server

=head1 SYNOPSIS

    use Test::PAGI::Server;

    my $test = Test::PAGI::Server->new(app => \&app);
    $test->start;

    my $response = $test->request(GET => '/');
    is($response->code, 200);

    $test->stop;

=head1 DESCRIPTION

Test utilities for running integration tests against PAGI::Server.

=cut

sub new {
    my ($class, %args) = @_;

    my $self = bless {
        app  => $args{app},
        port => $args{port} // 0,  # 0 = pick available port
    }, $class;
    return $self;
}

sub start {
    my ($self) = @_;

    # TODO: Implement - start server in background
}

sub stop {
    my ($self) = @_;

    # TODO: Implement - stop server
}

sub port {
    my ($self) = @_;

    return $self->{port};
}

sub base_url {
    my ($self) = @_;

    return "http://127.0.0.1:" . $self->port;
}

sub request {
    my ($self, $method, $path, %opts) = @_;

    # TODO: Implement - make HTTP request
}

sub websocket {
    my ($self, $path, %opts) = @_;

    # TODO: Implement - open WebSocket connection
}

1;

__END__

=head1 AUTHOR

John Napiorkowski E<lt>jjnapiork@cpan.orgE<gt>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
