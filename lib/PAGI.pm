package PAGI;

use strict;
use warnings;

our $VERSION = '0.002003';

1;

__END__

=encoding UTF-8

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
L<PAGI::Tutorial>. Coming from PSGI? See L<PAGI::PSGI>. Building a framework on
PAGI? See L<PAGI::Building>.

=head2 Why PAGI?

L<PSGI> models an application as a single, synchronous coderef that takes a
request and returns a response. That model has served Perl well, but it cannot
express long-lived connections such as long-poll HTTP or WebSockets: there is
only one path in (the request) and one path out (the response). Even made
non-blocking, a single request/response path cannot represent protocols that
deliver B<multiple> incoming events over the life of a connection, such as
WebSocket frames.

PAGI keeps the simple "your application is a coderef" idea but makes it
asynchronous and message-based. An application receives a C<$scope> describing
the connection and two async coderefs: C<$receive> for events arriving from the
client and C<$send> for events going back. Both return L<Future>s, so
backpressure is explicit. This allows any number of incoming and outgoing
events per connection, and leaves room for background work (for example,
listening on an external trigger like a message queue) alongside the
request/response flow.

PAGI is also a superset of L<PSGI>: there is a defined translation between the
two, so existing PSGI applications can run under a PAGI server through a PSGI
adapter provided in the C<PAGI-Tools> distribution.

=head2 Beta Software Notice

B<WARNING: This is beta software.>

This distribution (C<PAGI>) is the B<specification> only: this module plus the
L<PAGI::Spec> documentation. The reference implementations live in
separate distributions, each with its own stability level:

=over 4

=item B<Stable: PAGI Specification>

The PAGI specification (C<$scope>, C<$receive>, C<$send> interface) is stable.
Breaking changes will not be made except for critical security issues. Raw
PAGI applications you write today will continue to work.

See L<PAGI::Spec>.

=item B<Beta: PAGI-Server distribution>

The reference server (L<PAGI::Server>, validated against
L<PAGI::Server::Compliance>) handles HTTP/1.1, HTTP/2, WebSocket, and SSE
correctly, but has not been battle-tested in production. B<Recommendation:>
run behind a reverse proxy like nginx, Apache, or Caddy. Rely only on the
L<PAGI::Spec> interface, not on the server's internals. Ships in the
C<PAGI-Server> distribution.

=item B<Beta: PAGI-Tools distribution>

The application toolkit (L<PAGI::Request>, L<PAGI::Response>,
L<PAGI::WebSocket>, L<PAGI::SSE>, L<PAGI::Endpoint::Router>,
L<PAGI::App::Router>, middleware, and bundled apps) is convenience built on top
of the spec. These APIs may change between releases as the helpers evolve.
Ships in the C<PAGI-Tools> distribution.

=back

If you are interested in contributing to the future of async Perl web
development, your feedback, bug reports, and contributions are welcome.

=head1 THE PAGI ECOSYSTEM

PAGI is split across three distributions so that applications can depend on the
specification without pulling in a particular server or toolkit:

=over 4

=item C<PAGI> (this distribution)

The specification: this module plus the L<PAGI::Spec> documents
(L<PAGI::Spec>, L<PAGI::Spec::Www>, L<PAGI::Spec::Lifespan>,
L<PAGI::Spec::Extensions>, L<PAGI::Spec::Tls>, L<PAGI::Spec::Server>). The
specification modules are pure documentation;
during the transition from the combined distribution this distribution also
pulls in C<PAGI-Server> and C<PAGI-Tools> (see
L</INSTALLATION AND BACKWARD COMPATIBILITY>).

=item C<PAGI-Server>

The reference server (L<PAGI::Server>): an L<IO::Async>-based implementation
supporting HTTP/1.1, HTTP/2, WebSocket, SSE, TLS, and multi-worker pre-forking,
validated against L<PAGI::Server::Compliance>. Provides the C<pagi-server> CLI
and L<PAGI::Server::Runner>. L<PAGI::Spec::Server> documents the boundary
between application loading and the runtime PAGI application; server selection
and plugin compatibility are runner-specific APIs.

=item C<PAGI-Tools>

The application toolkit: the C<PAGI::Middleware::*> suite, C<PAGI::App::*>
ready-made apps, the C<PAGI::Endpoint::*> framework,
L<PAGI::Request>/L<PAGI::Response>/L<PAGI::Context> ergonomics, and
L<PAGI::Test::Client> and friends for in-process testing.

=back

This C<PAGI> distribution is the canonical starting point for the ecosystem:
the specification, the L<tutorial|PAGI::Tutorial>, a L<cookbook|PAGI::Cookbook>
of worked recipes, a L<migration guide|PAGI::PSGI> for people coming from PSGI,
a L<guide for framework authors|PAGI::Building>, and a set of raw-protocol
example applications under F<examples/> (including a complete little web
framework built on PAGI). The reference server lives in the
C<PAGI-Server> distribution and the application toolkit in C<PAGI-Tools>. The
project repository is L<https://github.com/jjn1056/pagi>; its history holds the
original combined distribution from before the split.

=head2 Built on PAGI

Beyond the core distributions, a growing set of projects target PAGI
directly. A sampling, roughly from full frameworks down to focused tools:

=over 4

=item L<Thunderhorse>

An asynchronous web framework built for PAGI from the ground up.

=item L<PAGI::FastAPI>

A FastAPI-style asynchronous microframework: C<Future::AsyncAwait>-native
handlers, type-safe request validation via L<Type::Tiny>, automatic OpenAPI
documentation, WebSocket support, and dependency injection, with concerns
like CORS, rate limiting, and authentication composed as middleware and
route dependencies.

=item L<WebDyne>

A long-standing server-page framework rendering F<.psp> files with embedded
Perl; it runs under Apache/mod_perl, PSGI, or PAGI as its application
runtime.

=item L<PAGI::Nano>

A compact micro-framework front door over C<PAGI-Tools>, aimed at demos and
small applications: routing, middleware, lifecycle, static files, streaming,
WebSocket, and SSE, arranged so a whole small app fits on one screen and
reads top to bottom.

=item L<Uniform::HTMX::PAGI>

Bridges L<Uniform::HTMX> into native PAGI web-context routines, with
chainable helpers (for example C<res_retarget>, C<res_trigger>) for shaping
HTMX response headers from PAGI applications.

=back

See the project repository for an up-to-date list of conforming servers,
frameworks, and tools -- and if you have built something on PAGI, open a
pull request adding it here.

=head2 Announcements

Release and specification announcements are posted to the C<pagi-announce>
mailing list at L<https://groups.google.com/g/pagi-announce>, and to the
project repository at L<https://github.com/jjn1056/pagi>.

=head1 INSTALLATION AND BACKWARD COMPATIBILITY

Before the split, the C<PAGI> distribution bundled the reference server, the
application toolkit, and the specification together, so C<cpanm PAGI> (or a
C<< requires 'PAGI' >> line in a F<cpanfile>) installed all of them.

To avoid breaking existing dependents, the C<PAGI> distribution B<continues to
pull in> L<PAGI::Server> (from the C<PAGI-Server> distribution) and
L<PAGI::Tools> (from the C<PAGI-Tools> distribution) as runtime dependencies
during the transition. Installing C<PAGI> therefore still gives you the server
and the toolkit, exactly as before the split.

B<This is temporary.> These convenience dependencies will be removed in a
future release. If your code uses the reference server or the toolkit, please
update your dependencies to require L<PAGI::Server> and/or L<PAGI::Tools>
directly, and depend on C<PAGI> only when you want the specification itself.

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

Applications built on the C<PAGI-Tools> toolkit rarely touch encoding at
all: L<PAGI::Request> decodes on the way in and L<PAGI::Response> encodes on
the way out, so handler code works purely in Perl character strings. The
rules below govern the B<raw interface> underneath -- the contract that
toolkits, frameworks, and servers implement so that applications never have
to.

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

Here is the same application written both ways. This is how it looks with
the toolkit, which is how most application code should look -- no C<Encode>
in sight:

    use PAGI::Request;
    use PAGI::Response;
    use Future::AsyncAwait;

    async sub app {
        my ($scope, $receive, $send) = @_;
        my $req  = PAGI::Request->new($scope, $receive);
        my $text = $req->query_param('text') // '';

        await PAGI::Response->new($scope)
            ->status(200)
            ->text("You sent: $text")
            ->respond($send);
    }

C<query_param> URL-decodes (including C<+> as space) and UTF-8-decodes with
replacement characters for invalid bytes (pass C<< strict => 1 >> to raise
instead); C<text> encodes the body as UTF-8, sets
C<text/plain; charset=utf-8>, and computes an authoritative
C<Content-Length> from the encoded bytes.

And here is the raw-interface equivalent -- what a toolkit like the one
above is doing on the application's behalf. It is shown so the underlying
contract is explicit, not as a recommended application style:

    use Future::AsyncAwait;
    use Encode qw(encode decode);
    use URI::Escape qw(uri_unescape);

    async sub app {
        my ($scope, $receive, $send) = @_;

        # Handle lifespan if your server sends it; otherwise fail on unsupported types.
        die "Unsupported type: $scope->{type}" unless $scope->{type} eq 'http';

        # Decode a query param by hand: split, '+' to space, percent-decode
        # to bytes, then UTF-8 decode.
        my $text = '';
        if ($scope->{query_string} =~ /(?:^|&)text=([^&]*)/) {
            (my $bytes = $1) =~ tr/+/ /;
            $bytes = uri_unescape($bytes);
            $text  = decode('UTF-8', $bytes, Encode::FB_DEFAULT);  # replacement for invalid
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

This distribution is the specification. To write and run PAGI applications,
install the reference server and toolkit:

    # Reference server (provides the pagi-server CLI) and toolkit
    cpanm PAGI::Server PAGI::Tools

    # Start a PAGI app
    pagi-server --app ./app.pl --port 5000

    # Test it
    curl http://localhost:5000/

See L<PAGI::Tutorial> for a step-by-step guide to the protocol, and
L<PAGI::Spec> for the full specification.

=head1 REQUIREMENTS

The specification modules (C<PAGI.pm> and the C<PAGI::Spec::*> POD)
are pure documentation and need only B<Perl 5.18+>. During the transition the
distribution additionally pulls in C<PAGI-Server> and C<PAGI-Tools> for
backward compatibility (see L</INSTALLATION AND BACKWARD COMPATIBILITY>); those
distributions declare their own dependencies (the C<PAGI-Server> distribution
requires L<IO::Async> and L<Future::AsyncAwait>; the C<PAGI-Tools> distribution
requires L<Future::AsyncAwait>).

=head1 SEE ALSO

=over 4

=item L<PAGI::Tutorial> - A step-by-step guide to the protocol

=item L<PAGI::Cookbook> - Worked, runnable recipes for each protocol feature

=item L<PAGI::PSGI> - Coming to PAGI from PSGI

=item L<PAGI::Building> - Building frameworks and toolkits on PAGI

=item L<PAGI::Spec> - The full PAGI specification

=item L<PAGI::Spec::Extensions> - The server extension mechanism

=item L<PAGI::Spec::Server> - Server and application-runner integration guidance

=item L<PAGI::Server> - Reference server (C<PAGI-Server> distribution)

=item L<PAGI::Server::Runner> - Application runner (C<PAGI-Server> distribution)

=item L<PSGI> - The synchronous predecessor to PAGI

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
