package PAGI;

use strict;
use warnings;

our $VERSION = '0.001019';

1;

__END__

=head1 NAME

PAGI - Perl Asynchronous Gateway Interface

=head1 DEDICATION

This project is dedicated to the memory of Matt S. Trout (mst), who I wish was
still around to tell me all the things wrong with my code while simultaneously
offering brilliant ideas to make it better.

Matt encouraged my first CPAN contribution. Without that encouragement, PAGI
and pretty much everything I've released on CPAN over 20+ years would never
have happened.

Thank you, Matt. The Perl community misses you.

=head1 SYNOPSIS

    # Raw PAGI application
    use Future::AsyncAwait;

    async sub app {
        my ($scope, $receive, $send) = @_;

        die "Unsupported: $scope->{type}" if $scope->{type} ne 'http';

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type => 'http.response.body',
            body => 'Hello from PAGI!',
            more => 0,
        });
    }

=head1 DESCRIPTION

PAGI (Perl Asynchronous Gateway Interface) is a specification for asynchronous
Perl web applications, designed as a spiritual successor to PSGI. It defines a
standard interface between async-capable Perl web servers, frameworks, and
applications, supporting HTTP/1.1, WebSocket, and Server-Sent Events (SSE).

This document presents a high level overview of L<PAGI>.  If you are a web developer
who is looking to write PAGI compliant apps, you should also review the tutorial:
L<PAGI::Tutorial>.

=head2 Beta Software Notice

B<WARNING: This is beta software.>

This distribution has different stability levels:

=over 4

=item B<Stable: PAGI Specification>

The PAGI specification (C<$scope>, C<$receive>, C<$send> interface) is stable.
Breaking changes will not be made except for critical security issues. Raw
PAGI applications you write today will continue to work.

See L<PAGI::Spec>

=item B<Stable: PAGI::Server>

The reference server has been validated against L<PAGI::Server::Compliance> and handles
HTTP/1.1, WebSocket, and SSE correctly. However, it has not been battle-tested
in production. B<Recommendation:> Run behind a reverse proxy like nginx, Apache,
or Caddy for production deployments.

Although I am marking this stable in terms of its interface, I reserve the right to
make internal code changes and reorganizations.   You should not rely on internal
details of the server for your application, just the L<PAGI::Spec> interface.

See L<PAGI::Server>, L<PAGI::Server::Compliance>.

=item B<Unstable: Everything Else>

L<PAGI::Request>, L<PAGI::Response>, L<PAGI::WebSocket>, L<PAGI::SSE>,
L<PAGI::Endpoint::Router>, L<PAGI::App::Router>, middleware, and bundled apps
are subject to change. These APIs may be modified to fix security issues,
resolve architectural problems, or improve the developer experience. You can
use them, but I reserve the right to make breaking changes between releases
as we continue to shape how these helpers work and impact the PAGI ecosystem.

=back

If you are interested in contributing to the future of async Perl web
development, your feedback, bug reports, and contributions are welcome.

=head1 COMPONENTS

This distribution includes:

=over 4

=item L<PAGI::Server>

Reference server implementation supporting HTTP/1.1, WebSocket, SSE, and
multi-worker mode with pre-forking.

=item L<PAGI::Lifespan>

Lifecycle management wrapper for PAGI applications. Handles startup/shutdown
callbacks and injects shared application state into request scopes.

=item L<PAGI::Request>

Convenience wrapper for HTTP request handling with body parsing, headers,
and state/stash accessors.

=item L<PAGI::WebSocket>

Convenience wrapper for WebSocket connections with JSON support, heartbeat,
and state/stash accessors.

=item L<PAGI::SSE>

Convenience wrapper for Server-Sent Events with event formatting, keepalive,
and periodic sending.

=item L<PAGI::Endpoint::Router>

Class-based router supporting HTTP, WebSocket, and SSE routes with parameter
capture and subrouter mounting.

=item L<PAGI::App::Router>

Functional router for building PAGI applications with Express-style routing.

=item L<PAGI::Middleware::*>

Collection of middleware components for common web application needs.

=item L<PAGI::App::*>

Bundled applications for common functionality (static files, health checks,
metrics, etc.).

=back

=head1 PAGI APPLICATION INTERFACE

PAGI applications are async coderefs with this signature:

    async sub app {
        my ($scope, $receive, $send) = @_;
     ... }

=head2 Parameters

=over 4

=item C<$scope>

Hashref containing connection metadata including type, headers, path, method,
query string, and server-advertised extensions.

=item C<$receive>

Async coderef that returns a Future resolving to the next event from the
client (e.g., request body chunks, WebSocket messages).

=item C<$send>

Async coderef that takes an event hashref and returns a Future. Used to send
responses back to the client.

=back

=head2 Scope Types

Applications dispatch on C<< $scope->{type} >>:

=over 4

=item C<http>

HTTP request/response (one scope per request)

=item C<websocket>

Persistent WebSocket connection

=item C<sse>

Server-Sent Events stream

=item C<lifespan>

Process startup/shutdown lifecycle events

=back

=head1 UTF-8 HANDLING OVERVIEW

PAGI scopes provide decoded text where mandated by the spec and preserve raw
bytes where the application must decide. Broad guidance:

=over 4

=item *
C<< $scope->{path} >> is UTF-8 decoded from the percent-encoded
C<< $scope->{raw_path} >>. If UTF-8 decoding fails (invalid byte sequences), the
original bytes are preserved as-is (Mojolicious-style fallback). If you need
exact on-the-wire bytes, use C<raw_path>.

=item *
C<< $scope->{query_string} >> and request bodies arrive as percent-encoded or raw
bytes. Higher-level frameworks may auto-decode with replacement by default, but
raw values remain available via C<query_string> and the body stream. If you
need strict validation, decode yourself with C<Encode> and C<FB_CROAK>.

=item *
Response bodies and header values sent over the wire must be encoded to bytes.
If you construct raw events, encode with C<Encode::encode('UTF-8', $str,
FB_CROAK)> (or another charset you set in Content-Type) and set
C<Content-Length> based on byte length.

=back

Raw PAGI example with explicit UTF-8 handling:

    use Future::AsyncAwait;
    use Encode qw(encode decode);

    async sub app {
        my ($scope, $receive, $send) = @_;

        # Handle lifespan if your server sends it; otherwise fail on unsupported types.
        die "Unsupported type: $scope->{type}" unless $scope->{type} eq 'http';

        # Decode query param manually (percent-decoded bytes)
        my $text = '';
        if ($scope->{query_string} =~ /text=([^&]+)/) {
            my $bytes = $1; $bytes =~ s/%([0-9A-Fa-f]{2})/chr hex $1/eg;
            $text = decode('UTF-8', $bytes, Encode::FB_DEFAULT);  # replacement for invalid
        }

        my $body = "You sent: $text";
        my $encoded = encode('UTF-8', $body, Encode::FB_CROAK);

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [
                ['content-type',   'text/plain; charset=utf-8'],
                ['content-length', length($encoded)],
            ],
        });
        await $send->({
            type => 'http.response.body',
            body => $encoded,
            more => 0,
        });
    }


=head1 QUICK START

    # Install dependencies
    cpanm --installdeps .

    # Run the test suite
    prove -l t/

    # Start a server with a PAGI app
    pagi-server --app examples/01-hello-http/app.pl --port 5000

    # Test it
    curl http://localhost:5000/

=head1 REQUIREMENTS

=over 4

=item * Perl 5.18+

=item * IO::Async (event loop, for PAGI::Server)

=item * Future::AsyncAwait (async/await support)

=back

=head1 SEE ALSO

=over 4

=item L<PAGI::Server> - Reference server implementation

=item L<PAGI::Request> - Convenience wrapper for request handling

=item L<PSGI> - The synchronous predecessor to PAGI

=item L<IO::Async> - Event loop used by PAGI::Server

=item L<Future::AsyncAwait> - Async/await for Perl

=back

=head1 CONTRIBUTING

This project is in active development. If you're interested in advancing
async web programming in Perl, contributions are welcome:

=over 4

=item * Bug reports and feature requests

=item * Documentation improvements

=item * Test coverage

=item * Protocol support (HTTP/2, HTTP/3)

=item * Performance optimizations

=back

=head1 AUTHOR

John Napiorkowski E<lt>jjnapiork@cpan.orgE<gt>

=head1 LICENSE

This software is licensed under the same terms as Perl itself.

=cut

