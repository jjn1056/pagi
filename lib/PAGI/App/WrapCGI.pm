package PAGI::App::WrapCGI;

use strict;
use warnings;
use Future::AsyncAwait;

=head1 NAME

PAGI::App::WrapCGI - Execute CGI scripts as PAGI apps

=head1 SYNOPSIS

    use PAGI::App::WrapCGI;

    my $app = PAGI::App::WrapCGI->new(
        script => '/path/to/script.cgi',
    )->to_app;

=cut

sub new {
    my ($class, %args) = @_;

    return bless {
        script  => $args{script},
        timeout => $args{timeout} // 30,
    }, $class;
}

sub to_app {
    my ($self) = @_;

    my $script = $self->{script};
    my $timeout = $self->{timeout};

    return async sub  {
        my ($scope, $receive, $send) = @_;
        die "Unsupported scope type: $scope->{type}" if $scope->{type} ne 'http';

        # Build CGI environment
        my %env = (
            REQUEST_METHOD  => $scope->{method},
            SCRIPT_NAME     => $scope->{script_name} // '',
            PATH_INFO       => $scope->{path},
            QUERY_STRING    => $scope->{query_string} // '',
            SERVER_PROTOCOL => 'HTTP/' . ($scope->{http_version} // '1.1'),
            SERVER_NAME     => $scope->{server}[0] // 'localhost',
            SERVER_PORT     => $scope->{server}[1] // 80,
            REMOTE_ADDR     => $scope->{client}[0] // '',
            REMOTE_PORT     => $scope->{client}[1] // 0,
            GATEWAY_INTERFACE => 'CGI/1.1',
        );

        # Add headers
        for my $h (@{$scope->{headers} // []}) {
            my ($name, $value) = @$h;
            my $key = uc($name);
            $key =~ s/-/_/g;
            if ($key eq 'CONTENT_TYPE') {
                $env{CONTENT_TYPE} = $value;
            } elsif ($key eq 'CONTENT_LENGTH') {
                $env{CONTENT_LENGTH} = $value;
            } else {
                $env{"HTTP_$key"} = $value;
            }
        }

        # Collect body
        my $body = '';
        while (1) {
            my $event = await $receive->();
            last if $event->{type} ne 'http.request';
            $body .= $event->{body} // '';
            last unless $event->{more};
        }

        # Execute CGI
        local %ENV = %env;
        my $pid = open my $fh, '-|';

        unless (defined $pid) {
            await $send->({
                type => 'http.response.start',
                status => 500,
                headers => [['content-type', 'text/plain']],
            });
            await $send->({ type => 'http.response.body', body => 'Internal Server Error', more => 0 });
            return;
        }

        if ($pid == 0) {
            # Child - run CGI
            if (length $body) {
                open my $stdin, '<', \$body;
                *STDIN = $stdin;
            }
            exec($script) or exit(1);
        }

        # Parent - read output
        local $/;
        my $output = <$fh>;
        close $fh;

        # Parse CGI output
        my ($headers, $resp_body) = split /\r?\n\r?\n/, $output // '', 2;
        my @resp_headers;
        my $status = 200;

        for my $line (split /\r?\n/, $headers // '') {
            my ($name, $value) = split /:\s*/, $line, 2;
            next unless $name;
            if (lc($name) eq 'status') {
                ($status) = $value =~ /^(\d+)/;
            } else {
                push @resp_headers, [lc($name), $value];
            }
        }

        await $send->({
            type => 'http.response.start',
            status => $status,
            headers => \@resp_headers,
        });
        await $send->({ type => 'http.response.body', body => $resp_body // '', more => 0 });
    };
}

1;

__END__

=head1 DESCRIPTION

Executes CGI scripts and converts their output to PAGI responses.
Sets up the standard CGI environment variables and parses the
CGI output (Status header, other headers, and body).

=head1 OPTIONS

=over 4

=item * C<script> - Path to the CGI script to execute

=item * C<timeout> - Execution timeout in seconds (default: 30)

=back

=cut
