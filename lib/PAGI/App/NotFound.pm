package PAGI::App::NotFound;

use strict;
use warnings;
use Future::AsyncAwait;

=head1 NAME

PAGI::App::NotFound - Customizable 404 response

=head1 SYNOPSIS

    use PAGI::App::NotFound;

    my $app = PAGI::App::NotFound->new(
        body => '<h1>Page not found</h1>',
        content_type => 'text/html',
    )->to_app;

=cut

sub new {
    my ($class, %args) = @_;

    return bless {
        body => $args{body} // 'Not Found',
        content_type => $args{content_type} // 'text/plain',
        status => $args{status} // 404,
    }, $class;
}

sub to_app {
    my ($self) = @_;

    my $body = $self->{body};
    my $content_type = $self->{content_type};
    my $status = $self->{status};

    return async sub  {
        my ($scope, $receive, $send) = @_;
        my $response_body = ref $body eq 'CODE' ? $body->($scope) : $body;

        await $send->({
            type => 'http.response.start',
            status => $status,
            headers => [
                ['content-type', $content_type],
                ['content-length', length($response_body)],
            ],
        });
        await $send->({ type => 'http.response.body', body => $response_body, more => 0 });
    };
}

1;

__END__

=head1 DESCRIPTION

Returns a customizable 404 (or other status) response. Useful as a
fallback in a Cascade.

=head1 OPTIONS

=over 4

=item * C<body> - Response body (string or coderef, default: 'Not Found')

=item * C<content_type> - Content-Type header (default: 'text/plain')

=item * C<status> - HTTP status code (default: 404)

=back

=cut
