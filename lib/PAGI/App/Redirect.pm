package PAGI::App::Redirect;

use strict;
use warnings;
use Future::AsyncAwait;

=head1 NAME

PAGI::App::Redirect - URL redirect app

=head1 SYNOPSIS

    use PAGI::App::Redirect;

    my $app = PAGI::App::Redirect->new(
        to => '/new-location',
        status => 301,
    )->to_app;

=cut

sub new {
    my ($class, %args) = @_;

    return bless {
        to => $args{to},
        status => $args{status} // 302,
        preserve_query => $args{preserve_query} // 1,
    }, $class;
}

sub to_app {
    my ($self) = @_;

    my $to = $self->{to};
    my $status = $self->{status};
    my $preserve_query = $self->{preserve_query};

    return async sub  {
        my ($scope, $receive, $send) = @_;
        my $location = ref $to eq 'CODE' ? $to->($scope) : $to;

        if ($preserve_query && $scope->{query_string}) {
            my $sep = $location =~ /\?/ ? '&' : '?';
            $location .= $sep . $scope->{query_string};
        }

        await $send->({
            type => 'http.response.start',
            status => $status,
            headers => [
                ['location', $location],
                ['content-type', 'text/plain'],
                ['content-length', 0],
            ],
        });
        await $send->({ type => 'http.response.body', body => '', more => 0 });
    };
}

1;

__END__

=head1 DESCRIPTION

Performs HTTP redirects. The target can be a static URL or a callback.

=head1 OPTIONS

=over 4

=item * C<to> - Target URL (string or coderef receiving $scope)

=item * C<status> - HTTP status code (default: 302)

=item * C<preserve_query> - Append query string to target (default: 1)

=back

=cut
