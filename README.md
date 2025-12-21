# PAGI - Perl Asynchronous Gateway Interface

PAGI is a specification for asynchronous Perl web applications, designed as a spiritual successor to PSGI. It defines a standard interface between async-capable Perl web servers, frameworks, and applications, supporting HTTP/1.1, WebSocket, and Server-Sent Events (SSE).

## Repository Contents

- **docs/** - PAGI specification documents
- **examples/** - Reference PAGI applications demonstrating the raw protocol
- **lib/** - Reference server implementation (PAGI::Server) and middleware
- **bin/** - CLI launcher (pagi-server)
- **t/** - Test suite

## Requirements

- Perl 5.16+
- cpanminus (for dependency installation)

## Quick Start

```bash
# Install dependencies
cpanm --installdeps .

# For best file-serving performance (zero-copy sendfile):
cpanm --installdeps . --with-recommends

# Run tests
prove -l t/

# Start the server with a PAGI app
pagi-server --app examples/01-hello-http/app.pl --port 5000

# Test it
curl http://localhost:5000/
```

## PAGI Application Interface

PAGI applications are async coderefs with this signature:

```perl
use Future::AsyncAwait;

async sub app {
    my ($scope, $receive, $send) = @_;

    die "Unsupported: $scope->{type}" if $scope->{type} ne 'http';

    await $send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [ ['content-type', 'text/plain'] ],
    });

    await $send->({
        type => 'http.response.body',
        body => "Hello from PAGI!",
        more => 0,
    });
}
```

### Parameters

- **$scope** - Hashref containing connection metadata (type, headers, path, etc.)
- **$receive** - Async coderef returning a Future that resolves to the next event
- **$send** - Async coderef taking an event hashref, returning a Future

### Scope Types

- `http` - HTTP request/response (one scope per request)
- `websocket` - Persistent WebSocket connection
- `sse` - Server-Sent Events stream
- `lifespan` - Process startup/shutdown lifecycle

## UTF-8 Handling

- `scope->{path}` is UTF-8 decoded from the percent-encoded `raw_path`. Use `raw_path` when you need on-the-wire bytes.
- `scope->{query_string}` and request bodies are byte data (often percent-encoded). Decode explicitly with `Encode` using replacement or strict modes as needed.
- Response bodies/headers must be bytes; set `Content-Length` from byte length. Encode with `Encode::encode('UTF-8', $str, FB_CROAK)` (or another charset you declare in `Content-Type`).

Minimal example with explicit UTF-8 handling:

```perl
use Future::AsyncAwait;
use experimental 'signatures';
use Encode qw(encode decode FB_DEFAULT FB_CROAK);

async sub app ($scope, $receive, $send) {
    die "Unsupported: $scope->{type}" if $scope->{type} ne 'http';

    my $text = '';
    if ($scope->{query_string} =~ /text=([^&]+)/) {
        my $bytes = $1; $bytes =~ s/%([0-9A-Fa-f]{2})/chr hex $1/eg;
        $text = decode('UTF-8', $bytes, FB_DEFAULT);  # replacement for invalid
    }

    my $body    = "You sent: $text";
    my $encoded = encode('UTF-8', $body, FB_CROAK);

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
```

## Example Applications

These examples demonstrate the low-level PAGI protocol directly:

| Example | Description |
|---------|-------------|
| 01-hello-http | Basic HTTP response |
| 02-streaming-response | Chunked streaming with trailers |
| 03-request-body | POST body handling |
| 04-websocket-echo | WebSocket echo server |
| 05-sse-broadcaster | Server-Sent Events |
| 06-lifespan-state | Shared state via lifespan |
| 07-extension-fullflush | TCP flush extension |
| 08-tls-introspection | TLS connection info |
| 09-psgi-bridge | PSGI compatibility |

## Middleware

PAGI includes a collection of middleware components in `PAGI::Middleware::*`:

- Authentication (Basic, Digest, Bearer)
- Sessions and Cookies
- Security (CORS, CSRF, Rate Limiting)
- Compression (GZIP)
- Logging and Metrics
- And many more

See `lib/PAGI/Middleware/` for the full list.

## PAGI::Simple Framework

For a higher-level Express/Sinatra-style framework, see [PAGI::Simple](https://github.com/jjn1056/PAGI-Simple) which is available as a separate distribution.

## Development

```bash
# Install development dependencies
cpanm --installdeps . --with-develop

# Build distribution
dzil build

# Run distribution tests
dzil test
```

## Specification

See [docs/specs/main.mkdn](docs/specs/main.mkdn) for the complete PAGI specification.

## License

This software is licensed under the same terms as Perl itself.

## Author

John Napiorkowski <jjnapiork@cpan.org>
