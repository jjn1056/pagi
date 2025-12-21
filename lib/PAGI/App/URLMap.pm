package PAGI::App::URLMap;

use strict;
use warnings;
use Future::AsyncAwait;

=head1 NAME

PAGI::App::URLMap - Mount apps at URL path prefixes

=head1 SYNOPSIS

    use PAGI::App::URLMap;

    my $map = PAGI::App::URLMap->new;
    $map->mount('/api' => $api_app);
    $map->mount('/static' => $static_app);
    my $app = $map->to_app;

=cut

sub new {
    my ($class, %args) = @_;

    return bless {
        mounts => [],
        default => $args{default},
    }, $class;
}

sub mount {
    my ($self, $path, $app) = @_;

    $path =~ s{/+$}{};  # Remove trailing slashes
    push @{$self->{mounts}}, [$path, $app];
    # Keep sorted by length (longest first) for proper matching
    @{$self->{mounts}} = sort { length($b->[0]) <=> length($a->[0]) } @{$self->{mounts}};
    return $self;
}

sub map {
    my ($self, $mapping) = @_;

    while (my ($path, $app) = each %$mapping) {
        $self->mount($path, $app);
    }
    return $self;
}

sub to_app {
    my ($self) = @_;

    my @mounts = @{$self->{mounts}};
    my $default = $self->{default};

    return async sub  {
        my ($scope, $receive, $send) = @_;
        my $path = $scope->{path} // '/';

        for my $mount (@mounts) {
            my ($prefix, $app) = @$mount;

            if ($prefix eq '' || $path eq $prefix || $path =~ /^\Q$prefix\E\//) {
                # Match found - adjust path for mounted app
                my $new_path = $path;
                $new_path =~ s/^\Q$prefix\E//;
                $new_path = '/' if $new_path eq '';

                my $new_scope = {
                    %$scope,
                    path => $new_path,
                    script_name => ($scope->{script_name} // '') . $prefix,
                };

                await $app->($new_scope, $receive, $send);
                return;
            }
        }

        # No match - use default or 404
        if ($default) {
            await $default->($scope, $receive, $send);
        } else {
            await $send->({
                type => 'http.response.start',
                status => 404,
                headers => [['content-type', 'text/plain']],
            });
            await $send->({ type => 'http.response.body', body => 'Not Found', more => 0 });
        }
    };
}

1;

__END__

=head1 DESCRIPTION

URLMap routes requests to different apps based on URL path prefix.
Longest prefix match wins. The mounted app sees an adjusted path
with the prefix removed.

=head1 OPTIONS

=over 4

=item * C<default> - App to use when no prefix matches

=back

=head1 METHODS

=head2 mount($prefix, $app)

Mount an app at the given path prefix.

=head2 map(\%mapping)

Mount multiple apps from a hashref of prefix => app pairs.

=cut
