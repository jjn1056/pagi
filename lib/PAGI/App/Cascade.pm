package PAGI::App::Cascade;

use strict;
use warnings;
use Future::AsyncAwait;

=head1 NAME

PAGI::App::Cascade - Try apps in sequence until success

=head1 SYNOPSIS

    use PAGI::App::Cascade;

    my $app = PAGI::App::Cascade->new(
        apps => [$static_app, $dynamic_app],
        catch => [404, 405],
    )->to_app;

=cut

sub new {
    my ($class, %args) = @_;

    return bless {
        apps  => $args{apps} // [],
        catch => { map { $_ => 1 } @{$args{catch} // [404, 405]} },
    }, $class;
}

sub add {
    my ($self, $app) = @_;

    push @{$self->{apps}}, $app;
    return $self;
}

sub to_app {
    my ($self) = @_;

    my @apps = @{$self->{apps}};
    my %catch = %{$self->{catch}};

    return async sub  {
        my ($scope, $receive, $send) = @_;
        for my $i (0 .. $#apps) {
            my $app = $apps[$i];
            my $is_last = ($i == $#apps);

            # For non-last apps, we need to capture the response
            if (!$is_last) {
                my @captured_events;
                my $captured_status;

                my $capture_send = async sub  {
        my ($event) = @_;
                    push @captured_events, $event;
                    if ($event->{type} eq 'http.response.start') {
                        $captured_status = $event->{status};
                    }
                };

                await $app->($scope, $receive, $capture_send);

                # Check if we should try next app
                if ($captured_status && $catch{$captured_status}) {
                    next;  # Try next app
                }

                # Send captured events
                for my $event (@captured_events) {
                    await $send->($event);
                }
                return;
            }

            # Last app - send directly
            await $app->($scope, $receive, $send);
            return;
        }
    };
}

1;

__END__

=head1 DESCRIPTION

Cascade tries apps in order until one returns a status code not in
the catch list. By default, 404 and 405 are caught, causing the next
app to be tried.

=head1 OPTIONS

=over 4

=item * C<apps> - Arrayref of apps to try in order

=item * C<catch> - Arrayref of status codes to catch (default: [404, 405])

=back

=head1 METHODS

=head2 add($app)

Add an app to the cascade.

=cut
