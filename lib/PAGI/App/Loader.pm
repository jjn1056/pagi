package PAGI::App::Loader;

use strict;
use warnings;
use Future::AsyncAwait;

=head1 NAME

PAGI::App::Loader - Load PAGI app from file

=head1 SYNOPSIS

    use PAGI::App::Loader;

    my $app = PAGI::App::Loader->new(
        file => 'app.pl',
    )->to_app;

=cut

sub new {
    my ($class, %args) = @_;

    return bless {
        file    => $args{file},
        reload  => $args{reload} // 0,
        _app    => undef,
        _mtime  => 0,
    }, $class;
}

sub to_app {
    my ($self) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        my $app = $self->_get_app();

        unless ($app) {
            await $send->({
                type => 'http.response.start',
                status => 500,
                headers => [['content-type', 'text/plain']],
            });
            await $send->({ type => 'http.response.body', body => 'App failed to load', more => 0 });
            return;
        }

        await $app->($scope, $receive, $send);
    };
}

sub _get_app {
    my ($self) = @_;

    my $file = $self->{file};

    # Check if reload needed
    if ($self->{reload} && $self->{_app}) {
        my @stat = stat($file);
        if (@stat && $stat[9] > $self->{_mtime}) {
            $self->{_app} = undef;
        }
    }

    return $self->{_app} if $self->{_app};

    # Load app
    my @stat = stat($file);
    $self->{_mtime} = $stat[9] if @stat;

    my $app = do $file;
    if ($@) {
        warn "Error loading $file: $@\n";
        return;
    }
    unless ($app) {
        warn "Error loading $file: $!\n" if $!;
        warn "$file did not return a coderef\n" unless $app;
        return;
    }
    unless (ref $app eq 'CODE') {
        warn "$file did not return a coderef\n";
        return;
    }

    $self->{_app} = $app;
    return $app;
}

1;

__END__

=head1 DESCRIPTION

Loads a PAGI app from a .pl file. Supports optional auto-reload
for development.

=head1 OPTIONS

=over 4

=item * C<file> - Path to the .pl file containing the PAGI app

=item * C<reload> - Auto-reload when file changes (default: 0)

=back

=head1 APP FILE FORMAT

The file should return a coderef:

    # app.pl
    use Future::AsyncAwait;

    async sub ($scope, $receive, $send) {
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'Hello', more => 0 });
    };

=cut
