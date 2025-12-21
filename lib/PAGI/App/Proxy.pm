package PAGI::App::Proxy;

use strict;
use warnings;
use Future::AsyncAwait;
use IO::Socket::INET;

=head1 NAME

PAGI::App::Proxy - HTTP reverse proxy

=head1 SYNOPSIS

    use PAGI::App::Proxy;

    my $app = PAGI::App::Proxy->new(
        backend => 'http://localhost:8080',
    )->to_app;

=cut

sub new {
    my ($class, %args) = @_;

    my $backend = $args{backend} // 'http://localhost:8080';
    my ($host, $port) = $backend =~ m{://([^:/]+)(?::(\d+))?};
    $port //= 80;

    return bless {
        host    => $host,
        port    => $port,
        timeout => $args{timeout} // 30,
        headers => $args{headers} // {},
    }, $class;
}

sub to_app {
    my ($self) = @_;

    my $host = $self->{host};
    my $port = $self->{port};
    my $timeout = $self->{timeout};
    my $extra_headers = $self->{headers};

    return async sub  {
        my ($scope, $receive, $send) = @_;
        die "Unsupported scope type: $scope->{type}" if $scope->{type} ne 'http';

        # Build request
        my $method = $scope->{method};
        my $path = $scope->{path};
        $path .= "?$scope->{query_string}" if $scope->{query_string};

        # Collect body
        my $body = '';
        while (1) {
            my $event = await $receive->();
            last if $event->{type} ne 'http.request';
            $body .= $event->{body} // '';
            last unless $event->{more};
        }

        # Build headers
        my @headers;
        for my $h (@{$scope->{headers} // []}) {
            next if lc($h->[0]) eq 'host';  # Replace host
            push @headers, "$h->[0]: $h->[1]";
        }
        push @headers, "Host: $host:$port";

        # Add X-Forwarded headers
        push @headers, "X-Forwarded-For: $scope->{client}[0]" if $scope->{client};
        push @headers, "X-Forwarded-Proto: $scope->{scheme}" if $scope->{scheme};

        # Add extra headers
        for my $name (keys %$extra_headers) {
            push @headers, "$name: $extra_headers->{$name}";
        }

        if (length $body) {
            push @headers, "Content-Length: " . length($body);
        }

        my $request = "$method $path HTTP/1.1\r\n" . join("\r\n", @headers) . "\r\n\r\n" . $body;

        # Connect to backend
        my $sock = IO::Socket::INET->new(
            PeerHost => $host,
            PeerPort => $port,
            Timeout  => $timeout,
        );

        unless ($sock) {
            await $send->({
                type => 'http.response.start',
                status => 502,
                headers => [['content-type', 'text/plain']],
            });
            await $send->({ type => 'http.response.body', body => 'Bad Gateway', more => 0 });
            return;
        }

        print $sock $request;

        # Read response
        my $response = '';
        while (my $chunk = <$sock>) {
            $response .= $chunk;
        }
        close $sock;

        # Parse response (simple parsing)
        my ($status_line, $rest) = split /\r?\n/, $response, 2;
        my ($proto, $status, $reason) = split / /, $status_line, 3;

        my ($header_block, $resp_body) = split /\r?\n\r?\n/, $rest, 2;
        my @resp_headers;
        for my $line (split /\r?\n/, $header_block // '') {
            my ($name, $value) = split /:\s*/, $line, 2;
            next unless $name;
            push @resp_headers, [lc($name), $value];
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

Simple HTTP reverse proxy. For production use, consider a more robust
implementation with connection pooling and async I/O.

=head1 OPTIONS

=over 4

=item * C<backend> - Backend URL (default: 'http://localhost:8080')

=item * C<timeout> - Connection timeout in seconds (default: 30)

=item * C<headers> - Hashref of additional headers to add to requests

=back

=cut
