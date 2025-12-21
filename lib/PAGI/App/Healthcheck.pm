package PAGI::App::Healthcheck;

use strict;
use warnings;
use Future::AsyncAwait;
use JSON::PP ();

=head1 NAME

PAGI::App::Healthcheck - Health check endpoint app

=head1 SYNOPSIS

    use PAGI::App::Healthcheck;

    my $app = PAGI::App::Healthcheck->new(
        checks => {
            database => sub { check_db() },
        },
    )->to_app;

=cut

our $START_TIME = time();

sub new {
    my ($class, %args) = @_;

    return bless {
        checks  => $args{checks} // {},
        version => $args{version},
    }, $class;
}

sub to_app {
    my ($self) = @_;

    my $checks = $self->{checks};
    my $version = $self->{version};

    return async sub  {
        my ($scope, $receive, $send) = @_;
        my $all_ok = 1;
        my %results;

        for my $name (sort keys %$checks) {
            my $check = $checks->{$name};
            my $result = { status => 'ok' };

            eval { my $ok = $check->(); $result->{status} = 'error' unless $ok; };
            if ($@) {
                $result->{status} = 'error';
                $result->{message} = "$@";
                $result->{message} =~ s/\s+$//;
            }

            $results{$name} = $result;
            $all_ok = 0 if $result->{status} eq 'error';
        }

        my $response = {
            status    => $all_ok ? 'ok' : 'error',
            timestamp => time(),
            uptime    => time() - $START_TIME,
        };
        $response->{version} = $version if defined $version;
        $response->{checks} = \%results if %results;

        my $body = JSON::PP::encode_json($response);
        my $status = $all_ok ? 200 : 503;

        await $send->({
            type => 'http.response.start',
            status => $status,
            headers => [
                ['content-type', 'application/json'],
                ['content-length', length($body)],
                ['cache-control', 'no-cache'],
            ],
        });
        await $send->({ type => 'http.response.body', body => $body, more => 0 });
    };
}

1;

__END__

=head1 DESCRIPTION

Returns JSON health status with optional custom checks.
Returns 200 for healthy, 503 for unhealthy.

=head1 OPTIONS

=over 4

=item * C<checks> - Hashref of name => coderef check functions

=item * C<version> - Application version to include in response

=back

=head1 RESPONSE FORMAT

    {
        "status": "ok",
        "timestamp": 1234567890,
        "uptime": 3600,
        "version": "1.0.0",
        "checks": {
            "database": { "status": "ok" },
            "cache": { "status": "error", "message": "Connection refused" }
        }
    }

=cut
