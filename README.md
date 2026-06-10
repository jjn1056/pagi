# PAGI — Perl Asynchronous Gateway Interface

**An async successor to PSGI: HTTP, WebSocket, and SSE behind one small, stable, loop-agnostic protocol.**

[![CI](https://github.com/jjn1056/pagi/actions/workflows/ci.yml/badge.svg)](https://github.com/jjn1056/pagi/actions)

PSGI models a web application as a single *synchronous* coderef: it takes an
`$env` and returns `[$status, \@headers, \@body]`. That cannot express a
connection that stays open and exchanges many messages — long-poll,
Server-Sent Events, WebSockets — because there is only one way in and one way
out.

PAGI keeps the idea you like — **your application is a coderef** — but makes it
asynchronous and message-based. Your app receives a connection `$scope` and two
coderefs (`$receive` for events from the client, `$send` for events back), and
that is essentially the whole specification. The same application runs unchanged
on any conforming server, under any event loop.

And because **PAGI is a superset of PSGI**, you don't have to rewrite anything:
run your existing PSGI app under PAGI and add async endpoints beside it.

## A complete PAGI application

```perl
use strict;
use warnings;
use Future::AsyncAwait;

my $app = async sub {
    my ($scope, $receive, $send) = @_;

    await $send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [ ['content-type', 'text/plain'] ],
    });
    await $send->({ type => 'http.response.body', body => 'Hello from PAGI!' });
};

$app;
```

Run it with the reference server (`pagi-server`, from the `PAGI-Server`
distribution). And for proof that this is a foundation worth building on,
[`examples/mini-framework`](examples/mini-framework) is a complete little web
framework — routing, path parameters, genuinely non-blocking async dispatch —
in about fifty lines of plain Perl.

## Coming from PSGI? Building a framework?

- **Migrating from PSGI** → [`PAGI::PSGI`](lib/PAGI/PSGI.pod) — the mental-model
  mapping (`$env`→`$scope`, response→`$send`, `psgi.input`→`$receive`,
  middleware) and the incremental on-ramp via `PAGI::App::WrapPSGI`.
- **Building a framework or toolkit on PAGI** → [`PAGI::Building`](lib/PAGI/Building.pod)
  — the layering model, middleware, and extending the protocol.

## Where to start

| If you want to… | Read |
| --- | --- |
| Understand what PAGI is | [`PAGI`](lib/PAGI.pm) |
| Learn the protocol from scratch | [`PAGI::Tutorial`](lib/PAGI/Tutorial.pod) |
| See worked, runnable recipes | [`PAGI::Cookbook`](lib/PAGI/Cookbook.pod) |
| Migrate from PSGI | [`PAGI::PSGI`](lib/PAGI/PSGI.pod) |
| Build a framework on it | [`PAGI::Building`](lib/PAGI/Building.pod) |
| Read the formal specification | [`PAGI::Spec`](lib/PAGI/Spec.pod) |
| Run something | [`examples/`](examples/) |

(POD renders nicely with `perldoc PAGI::Tutorial` or on MetaCPAN once released.)

## The ecosystem

PAGI is split across three distributions so applications can depend on the
specification without pulling in a particular server or toolkit:

- **PAGI** (this repository) — the specification, tutorial, cookbook, and
  example applications.
- **PAGI-Server** — the reference server: HTTP/1.1, HTTP/2, WebSocket, SSE, TLS,
  multi-worker, and the `pagi-server` CLI. Any server implementing the contract
  in `PAGI::Spec::Server` is a drop-in alternative.
- **PAGI-Tools** — the application toolkit: middleware, ready-made apps, the
  endpoint/router framework, request/response helpers, and `PAGI::App::WrapPSGI`.

## Status

**Beta.** The PAGI *specification* is stable — breaking changes will not be made
except for critical security issues, so raw PAGI applications you write today
will keep working. The reference server and toolkit are beta. Requires **Perl
5.18+**.

This is a labor of love for the future of async web programming in Perl.
Feedback, bug reports, and contributions are welcome.

## License

Copyright John Napiorkowski. Licensed under the same terms as Perl itself.
