# PAGI - Perl Asynchronous Gateway Interface

PAGI is a specification for asynchronous Perl web applications, designed as a spiritual successor to PSGI. It defines a standard interface between async-capable Perl web servers, frameworks, and applications, supporting HTTP/1.1, WebSocket, and Server-Sent Events (SSE).

## Repository Contents

- **docs/** - PAGI specification documents
- **examples/** - Reference PAGI applications (raw PAGI and PAGI::Simple)
- **lib/** - Reference server implementation (PAGI::Server) and micro-framework (PAGI::Simple)
- **bin/** - CLI launcher (pagi-server)
- **t/** - Test suite

## Requirements

- Perl 5.32+ (required for native subroutine signatures)
- cpanminus (for dependency installation)

## Quick Start

```bash
# Set up environment (installs dependencies)
cpanm --installdeps .

# Run tests
prove -l t/

# Start the server with a raw PAGI app
pagi-server --app examples/01-hello-http/app.pl --port 5000

# Or with a PAGI::Simple app
pagi-server --app examples/simple-01-hello/app.pl --port 5000

# Test it
curl http://localhost:5000/
```

## PAGI Application Interface

PAGI applications are async coderefs with this signature:

```perl
use Future::AsyncAwait;
use experimental 'signatures';

async sub app ($scope, $receive, $send) {
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

## PAGI::Simple Micro-Framework

For simpler applications, use the PAGI::Simple micro-framework:

```perl
use PAGI::Simple;

my $app = PAGI::Simple->new(name => 'My App');

$app->get('/' => sub ($c) {
    $c->text("Hello, World!");
});

$app->get('/greet/:name' => sub ($c) {
    my $name = $c->path_params->{name};
    $c->json({ greeting => "Hello, $name!" });
});

$app->websocket('/ws' => sub ($ws) {
    $ws->on(message => sub ($data) {
        $ws->send("Echo: $data");
    });
});

$app->to_app;
```

## UTF-8 Handling (Raw PAGI)

- `scope->{path}` is UTF-8 decoded from the percent-encoded `raw_path`. Use `raw_path` when you need on-the-wire bytes.
- `scope->{query_string}` and request bodies are byte data (often percent-encoded). Decode explicitly with `Encode` using replacement or strict modes as needed.
- Response bodies/headers must be bytes; set `Content-Length` from byte length. Encode with `Encode::encode('UTF-8', $str, FB_CROAK)` (or another charset you declare in `Content-Type`).

Minimal raw example with explicit UTF-8 handling:

```perl
use Future::AsyncAwait;
use experimental 'signatures';
use Encode qw(encode decode FB_DEFAULT FB_CROAK);

async sub app ($scope, $receive, $send) {
    # Handle lifespan if your server sends it; otherwise fail on unsupported types.
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

For a higher-level default-decoding experience (with raw/strict options), see `PAGI::Simple`.
Browse the `examples/` directory for end-to-end apps (both raw PAGI and PAGI::Simple) including UTF-8-focused demos.

## Example Applications

### Raw PAGI Examples

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

### PAGI::Simple Examples

These examples use the PAGI::Simple micro-framework for easier development:

| Example | Description |
|---------|-------------|
| simple-01-hello | Basic routing, path params, JSON/HTML responses |
| simple-02-forms | Form processing, REST API, CRUD operations |
| simple-03-websocket | WebSocket chat with rooms and broadcasting |
| simple-04-sse | Server-Sent Events with channels |

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
