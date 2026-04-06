# PAGI::Context Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add PAGI::Context as a factory + base class with protocol-specific subclasses (HTTP, WebSocket, SSE) that provide lazy access to protocol helpers and shared state via a unified handler signature.

**Architecture:** Factory pattern — `PAGI::Context->new($scope, $receive, $send)` inspects `$scope->{type}` via overridable `_type_map`/`_resolve_class` and blesses into the appropriate subclass. Shared methods live on the base class; protocol-specific accessors (request/response, websocket, sse) live on subclasses.

**Tech Stack:** Perl 5.18+, Test2::V0, Future::AsyncAwait, plain `bless` OOP (no Moo/Moose/Role::Tiny)

**Spec:** `docs/superpowers/specs/2026-04-06-pagi-context-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `lib/PAGI/Context.pm` | Create | Base class + factory + shared methods |
| `lib/PAGI/Context/HTTP.pm` | Create | HTTP subclass (request, response, method) |
| `lib/PAGI/Context/WebSocket.pm` | Create | WebSocket subclass (websocket) |
| `lib/PAGI/Context/SSE.pm` | Create | SSE subclass (sse) |
| `t/context/01-factory.t` | Create | Factory resolution tests |
| `t/context/02-shared.t` | Create | Shared method tests (scope, stash, session, connection) |
| `t/context/03-http.t` | Create | HTTP subclass tests |
| `t/context/04-websocket.t` | Create | WebSocket subclass tests |
| `t/context/05-sse.t` | Create | SSE subclass tests |
| `t/context/06-extension.t` | Create | Subclassing / custom type map tests |
| `t/context/07-router.t` | Create | Endpoint::Router integration tests |
| `lib/PAGI/Endpoint/Router.pm` | Modify | Inject `$ctx` instead of `($req,$res)` / `($ws)` / `($sse)` |
| `t/endpoint-router.t` | Modify | Update handler signatures to `($ctx)` |
| `examples/endpoint-demo/app.pl` | Modify | Update to use `$ctx` signature |
| `examples/endpoint-router-demo/lib/MyApp/Main.pm` | Modify | Update to use `$ctx` signature |
| `examples/endpoint-router-demo/lib/MyApp/API.pm` | Modify | Update to use `$ctx` signature |

---

### Task 1: PAGI::Context Base Class — Factory + Scope Accessors

**Files:**
- Create: `lib/PAGI/Context.pm`
- Create: `t/context/01-factory.t`

- [ ] **Step 1: Write the factory and scope accessor tests**

Create `t/context/01-factory.t`:

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use PAGI::Context;

subtest 'module loads and has expected methods' => sub {
    ok(PAGI::Context->can('new'), 'has new');
    ok(PAGI::Context->can('_type_map'), 'has _type_map');
    ok(PAGI::Context->can('_resolve_class'), 'has _resolve_class');
    ok(PAGI::Context->can('scope'), 'has scope');
    ok(PAGI::Context->can('type'), 'has type');
    ok(PAGI::Context->can('path'), 'has path');
};

subtest '_type_map returns expected mapping' => sub {
    my $map = PAGI::Context->_type_map;
    is(ref($map), 'HASH', 'returns hashref');
    is($map->{http}, 'PAGI::Context::HTTP', 'http maps to HTTP');
    is($map->{websocket}, 'PAGI::Context::WebSocket', 'websocket maps to WebSocket');
    is($map->{sse}, 'PAGI::Context::SSE', 'sse maps to SSE');
};

subtest '_resolve_class returns correct subclass' => sub {
    is(PAGI::Context->_resolve_class({ type => 'http' }),
        'PAGI::Context::HTTP', 'http type resolves');
    is(PAGI::Context->_resolve_class({ type => 'websocket' }),
        'PAGI::Context::WebSocket', 'websocket type resolves');
    is(PAGI::Context->_resolve_class({ type => 'sse' }),
        'PAGI::Context::SSE', 'sse type resolves');
    is(PAGI::Context->_resolve_class({}),
        'PAGI::Context::HTTP', 'missing type defaults to HTTP');
    is(PAGI::Context->_resolve_class({ type => 'unknown' }),
        'PAGI::Context::HTTP', 'unknown type defaults to HTTP');
};

subtest 'new returns correct subclass' => sub {
    my $receive = sub {};
    my $send = sub {};

    my $http_ctx = PAGI::Context->new(
        { type => 'http', method => 'GET', path => '/test', headers => [] },
        $receive, $send,
    );
    isa_ok($http_ctx, 'PAGI::Context');
    isa_ok($http_ctx, 'PAGI::Context::HTTP');

    my $ws_ctx = PAGI::Context->new(
        { type => 'websocket', path => '/ws', headers => [] },
        $receive, $send,
    );
    isa_ok($ws_ctx, 'PAGI::Context');
    isa_ok($ws_ctx, 'PAGI::Context::WebSocket');

    my $sse_ctx = PAGI::Context->new(
        { type => 'sse', path => '/events', headers => [] },
        $receive, $send,
    );
    isa_ok($sse_ctx, 'PAGI::Context');
    isa_ok($sse_ctx, 'PAGI::Context::SSE');
};

subtest 'scope accessors work' => sub {
    my $scope = {
        type         => 'http',
        method       => 'GET',
        path         => '/hello',
        raw_path     => '/hello%20world',
        query_string => 'a=1&b=2',
        scheme       => 'https',
        client       => ['127.0.0.1', 8080],
        server       => ['0.0.0.0', 443],
        headers      => [['host', 'example.com'], ['accept', 'text/html']],
    };

    my $ctx = PAGI::Context->new($scope, sub {}, sub {});

    is($ctx->scope, $scope, 'scope returns raw hashref');
    is($ctx->type, 'http', 'type accessor');
    is($ctx->path, '/hello', 'path accessor');
    is($ctx->raw_path, '/hello%20world', 'raw_path accessor');
    is($ctx->query_string, 'a=1&b=2', 'query_string accessor');
    is($ctx->scheme, 'https', 'scheme accessor');
    is($ctx->client, ['127.0.0.1', 8080], 'client accessor');
    is($ctx->server, ['0.0.0.0', 443], 'server accessor');
    is($ctx->headers, $scope->{headers}, 'headers accessor');
};

subtest 'scope accessor defaults' => sub {
    my $ctx = PAGI::Context->new({ type => 'http', headers => [] }, sub {}, sub {});

    is($ctx->raw_path, undef, 'raw_path undef when path undef');
    is($ctx->query_string, '', 'query_string defaults to empty string');
    is($ctx->scheme, 'http', 'scheme defaults to http');
};

subtest 'protocol introspection' => sub {
    my $receive = sub {};
    my $send = sub {};

    my $http = PAGI::Context->new({ type => 'http', headers => [] }, $receive, $send);
    ok($http->is_http, 'is_http true');
    ok(!$http->is_websocket, 'is_websocket false');
    ok(!$http->is_sse, 'is_sse false');

    my $ws = PAGI::Context->new({ type => 'websocket', headers => [] }, $receive, $send);
    ok(!$ws->is_http, 'is_http false');
    ok($ws->is_websocket, 'is_websocket true');
    ok(!$ws->is_sse, 'is_sse false');

    my $sse = PAGI::Context->new({ type => 'sse', headers => [] }, $receive, $send);
    ok(!$sse->is_http, 'is_http false');
    ok(!$sse->is_websocket, 'is_websocket false');
    ok($sse->is_sse, 'is_sse true');
};

subtest 'header lookup' => sub {
    my $scope = {
        type    => 'http',
        headers => [
            ['host', 'example.com'],
            ['accept', 'text/html'],
            ['accept', 'application/json'],
            ['X-Custom', 'value'],
        ],
    };

    my $ctx = PAGI::Context->new($scope, sub {}, sub {});

    is($ctx->header('host'), 'example.com', 'header lookup');
    is($ctx->header('Host'), 'example.com', 'case-insensitive');
    is($ctx->header('accept'), 'application/json', 'returns last value');
    is($ctx->header('x-custom'), 'value', 'case-insensitive custom header');
    is($ctx->header('nonexistent'), undef, 'missing header returns undef');
};

subtest 'receive and send accessors' => sub {
    my $receive = sub { 'receive' };
    my $send = sub { 'send' };

    my $ctx = PAGI::Context->new({ type => 'http', headers => [] }, $receive, $send);

    is($ctx->receive, $receive, 'receive returns coderef');
    is($ctx->send, $send, 'send returns coderef');
};

done_testing;
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/context/01-factory.t'`
Expected: FAIL — `Can't locate PAGI/Context.pm`

- [ ] **Step 3: Create PAGI::Context base class with factory, scope accessors, and POD**

Create `lib/PAGI/Context.pm`:

```perl
package PAGI::Context;

use strict;
use warnings;
use Scalar::Util 'blessed';

=head1 NAME

PAGI::Context - Per-request context with protocol-specific subclasses

=head1 SYNOPSIS

    use PAGI::Context;

    # Factory returns the right subclass based on scope type
    my $ctx = PAGI::Context->new($scope, $receive, $send);

    # Shared methods (all protocol types)
    my $type = $ctx->type;        # 'http', 'websocket', 'sse'
    my $path = $ctx->path;
    my $stash = $ctx->stash;      # PAGI::Stash
    my $session = $ctx->session;  # PAGI::Session

    # Protocol-specific (only on the appropriate subclass)
    my $req = $ctx->request;      # HTTP only
    my $res = $ctx->response;     # HTTP only
    my $ws  = $ctx->websocket;    # WebSocket only
    my $sse = $ctx->sse;          # SSE only

=head1 DESCRIPTION

PAGI::Context is a factory and base class that provides a unified entry
point for per-request context. Calling C<< PAGI::Context->new(...) >>
inspects C<< $scope->{type} >> and returns the appropriate subclass:
L<PAGI::Context::HTTP>, L<PAGI::Context::WebSocket>, or
L<PAGI::Context::SSE>.

Shared methods (scope accessors, stash, session, connection state) live
on the base class. Protocol-specific methods (request/response, websocket,
sse) live on subclasses and simply do not exist on other protocol types.

=head1 EXTENSIBILITY

Override C<_type_map> to add or replace protocol types:

    package MyApp::Context;
    our @ISA = ('PAGI::Context');

    sub _type_map {
        my ($class) = @_;
        return {
            %{ $class->SUPER::_type_map },
            grpc => 'MyApp::Context::GRPC',
        };
    }

Override C<_resolve_class> for custom resolution logic beyond the type map.

=head1 CONSTRUCTOR

=head2 new

    my $ctx = PAGI::Context->new($scope, $receive, $send);

Factory constructor. Returns a subclass instance based on
C<< $scope->{type} >>. Defaults to HTTP if type is missing or unknown.

=cut

sub new {
    my ($class, $scope, $receive, $send) = @_;
    my $subclass = $class->_resolve_class($scope);
    return bless {
        scope   => $scope,
        receive => $receive,
        send    => $send,
    }, $subclass;
}

=head1 CLASS METHODS

=head2 _type_map

    my $map = PAGI::Context->_type_map;

Returns a hashref mapping scope type strings to subclass package names.
Override in a subclass to add or replace protocol types.

=cut

sub _type_map {
    return {
        http      => 'PAGI::Context::HTTP',
        websocket => 'PAGI::Context::WebSocket',
        sse       => 'PAGI::Context::SSE',
    };
}

=head2 _resolve_class

    my $class = PAGI::Context->_resolve_class($scope);

Resolves the scope to a subclass package name. Looks up
C<< $scope->{type} >> in C<_type_map>; defaults to the C<http> mapping
if the type is missing or unknown. Override for custom resolution logic.

=cut

sub _resolve_class {
    my ($class, $scope) = @_;
    my $type = $scope->{type} // 'http';
    return $class->_type_map->{$type} // $class->_type_map->{http};
}

=head1 METHODS

=head2 Scope Accessors

    $ctx->scope;          # raw $scope hashref
    $ctx->type;           # $scope->{type}
    $ctx->path;           # $scope->{path}
    $ctx->raw_path;       # $scope->{raw_path} // $scope->{path}
    $ctx->query_string;   # $scope->{query_string} // ''
    $ctx->scheme;         # $scope->{scheme} // 'http'
    $ctx->client;         # $scope->{client}
    $ctx->server;         # $scope->{server}
    $ctx->headers;        # $scope->{headers} arrayref of [name, value]

=cut

sub scope        { shift->{scope} }
sub type         { shift->{scope}{type} }
sub path         { shift->{scope}{path} }
sub raw_path     { my $s = shift; $s->{scope}{raw_path} // $s->{scope}{path} }
sub query_string { shift->{scope}{query_string} // '' }
sub scheme       { shift->{scope}{scheme} // 'http' }
sub client       { shift->{scope}{client} }
sub server       { shift->{scope}{server} }
sub headers      { shift->{scope}{headers} }

=head2 Protocol Introspection

    $ctx->is_http;        # true if type eq 'http'
    $ctx->is_websocket;   # true if type eq 'websocket'
    $ctx->is_sse;         # true if type eq 'sse'

=cut

sub is_http      { (shift->{scope}{type} // '') eq 'http' }
sub is_websocket { (shift->{scope}{type} // '') eq 'websocket' }
sub is_sse       { (shift->{scope}{type} // '') eq 'sse' }

=head2 header

    my $value = $ctx->header('Content-Type');

Returns the last value for the named header (case-insensitive), or
C<undef> if not found.

=cut

sub header {
    my ($self, $name) = @_;
    $name = lc($name);
    my $value;
    for my $pair (@{$self->{scope}{headers} // []}) {
        if (lc($pair->[0]) eq $name) {
            $value = $pair->[1];
        }
    }
    return $value;
}

=head2 receive

    my $receive = $ctx->receive;

Returns the raw C<$receive> coderef.

=head2 send

    my $send = $ctx->send;

Returns the raw C<$send> coderef.

=cut

sub receive { shift->{receive} }
sub send    { shift->{send} }

=head2 stash

    my $stash = $ctx->stash;   # PAGI::Stash instance

Returns a L<PAGI::Stash> wrapping C<< $scope->{'pagi.stash'} >>.
Lazy-constructed and cached.

=head2 session

    my $session = $ctx->session;   # PAGI::Session instance

Returns a L<PAGI::Session> wrapping C<< $scope->{'pagi.session'} >>.
Lazy-constructed and cached. Dies if session middleware has not run.

=head2 state

    my $state = $ctx->state;   # hashref

Returns C<< $scope->{state} >> — the app/endpoint-level shared state.

=cut

sub stash {
    my ($self) = @_;
    return $self->{_stash} //= do {
        require PAGI::Stash;
        PAGI::Stash->new($self->{scope});
    };
}

sub session {
    my ($self) = @_;
    return $self->{_session} //= do {
        require PAGI::Session;
        PAGI::Session->new($self->{scope});
    };
}

sub state {
    my ($self) = @_;
    return $self->{scope}{state} // {};
}

=head2 Connection State

    $ctx->connection;           # PAGI::Server::ConnectionState object
    $ctx->is_connected;         # boolean
    $ctx->is_disconnected;      # boolean
    $ctx->disconnect_reason;    # string or undef
    $ctx->on_disconnect($cb);   # register callback

Delegates to C<< $scope->{'pagi.connection'} >>.

=cut

sub connection {
    my ($self) = @_;
    return $self->{scope}{'pagi.connection'};
}

sub is_connected {
    my ($self) = @_;
    my $conn = $self->connection;
    return 0 unless $conn;
    return $conn->is_connected;
}

sub is_disconnected {
    my ($self) = @_;
    return !$self->is_connected;
}

sub disconnect_reason {
    my ($self) = @_;
    my $conn = $self->connection;
    return undef unless $conn;
    return $conn->disconnect_reason;
}

sub on_disconnect {
    my ($self, $cb) = @_;
    my $conn = $self->connection;
    return unless $conn;
    $conn->on_disconnect($cb);
}

# Load subclasses
require PAGI::Context::HTTP;
require PAGI::Context::WebSocket;
require PAGI::Context::SSE;

1;

__END__

=head1 SEE ALSO

L<PAGI::Context::HTTP>, L<PAGI::Context::WebSocket>, L<PAGI::Context::SSE>,
L<PAGI::Stash>, L<PAGI::Session>

=cut
```

Create minimal stubs for subclasses so `require` succeeds.

Create `lib/PAGI/Context/HTTP.pm`:

```perl
package PAGI::Context::HTTP;

use strict;
use warnings;

our @ISA = ('PAGI::Context');

1;
```

Create `lib/PAGI/Context/WebSocket.pm`:

```perl
package PAGI::Context::WebSocket;

use strict;
use warnings;

our @ISA = ('PAGI::Context');

1;
```

Create `lib/PAGI/Context/SSE.pm`:

```perl
package PAGI::Context::SSE;

use strict;
use warnings;

our @ISA = ('PAGI::Context');

1;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/context/01-factory.t'`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add lib/PAGI/Context.pm lib/PAGI/Context/HTTP.pm lib/PAGI/Context/WebSocket.pm lib/PAGI/Context/SSE.pm t/context/01-factory.t
git commit -m "feat: add PAGI::Context base class with factory and scope accessors"
```

---

### Task 2: Shared State and Connection Methods

**Files:**
- Create: `t/context/02-shared.t`
- Modify: `lib/PAGI/Context.pm` (already has the methods — this task tests them)

- [ ] **Step 1: Write tests for stash, session, state, and connection**

Create `t/context/02-shared.t`:

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use PAGI::Context;
use PAGI::Stash;
use PAGI::Session;

subtest 'stash accessor' => sub {
    my $scope = { type => 'http', headers => [] };
    my $ctx = PAGI::Context->new($scope, sub {}, sub {});

    my $stash = $ctx->stash;
    isa_ok($stash, 'PAGI::Stash');

    # Cached — same object returned
    my $stash2 = $ctx->stash;
    ok($stash == $stash2, 'stash is cached');

    # Mutations visible through scope
    $stash->set(user => 'alice');
    is($scope->{'pagi.stash'}{user}, 'alice', 'stash writes to scope');
};

subtest 'session accessor' => sub {
    my $scope = {
        type           => 'http',
        headers        => [],
        'pagi.session' => { _id => 'sess-123', user_id => 42 },
    };
    my $ctx = PAGI::Context->new($scope, sub {}, sub {});

    my $session = $ctx->session;
    isa_ok($session, 'PAGI::Session');
    is($session->id, 'sess-123', 'session id accessible');
    is($session->get('user_id'), 42, 'session data accessible');

    # Cached
    my $session2 = $ctx->session;
    ok($session == $session2, 'session is cached');
};

subtest 'session dies without middleware' => sub {
    my $ctx = PAGI::Context->new({ type => 'http', headers => [] }, sub {}, sub {});
    ok(dies { $ctx->session }, 'session dies when pagi.session missing');
};

subtest 'state accessor' => sub {
    my $scope = {
        type    => 'http',
        headers => [],
        state   => { db => 'connected' },
    };
    my $ctx = PAGI::Context->new($scope, sub {}, sub {});

    is($ctx->state->{db}, 'connected', 'state returns scope state');
};

subtest 'state defaults to empty hashref' => sub {
    my $ctx = PAGI::Context->new({ type => 'http', headers => [] }, sub {}, sub {});
    is($ctx->state, {}, 'state defaults to empty hashref');
};

subtest 'connection state without connection object' => sub {
    my $ctx = PAGI::Context->new({ type => 'http', headers => [] }, sub {}, sub {});

    is($ctx->connection, undef, 'connection returns undef when not set');
    is($ctx->is_connected, 0, 'is_connected returns 0 without connection');
    ok($ctx->is_disconnected, 'is_disconnected returns true without connection');
    is($ctx->disconnect_reason, undef, 'disconnect_reason returns undef');
};

subtest 'connection state with mock connection' => sub {
    my $connected = 1;
    my @callbacks;

    # Minimal duck-type mock for ConnectionState
    my $mock_conn = bless {}, 'MockConnState';
    {
        no strict 'refs';
        *MockConnState::is_connected = sub { $connected };
        *MockConnState::disconnect_reason = sub { $connected ? undef : 'client_gone' };
        *MockConnState::on_disconnect = sub { push @callbacks, $_[1] };
    }

    my $scope = {
        type               => 'http',
        headers            => [],
        'pagi.connection'  => $mock_conn,
    };
    my $ctx = PAGI::Context->new($scope, sub {}, sub {});

    ok($ctx->is_connected, 'is_connected delegates');
    ok(!$ctx->is_disconnected, 'is_disconnected delegates');
    is($ctx->disconnect_reason, undef, 'disconnect_reason undef while connected');

    $connected = 0;
    ok(!$ctx->is_connected, 'is_connected updates');
    ok($ctx->is_disconnected, 'is_disconnected updates');
    is($ctx->disconnect_reason, 'client_gone', 'disconnect_reason set');

    my $cb = sub { 'called' };
    $ctx->on_disconnect($cb);
    is(scalar @callbacks, 1, 'on_disconnect registers callback');
    is($callbacks[0], $cb, 'correct callback registered');
};

subtest 'stash shared across protocol helpers' => sub {
    my $scope = { type => 'http', method => 'GET', path => '/', headers => [] };
    my $ctx = PAGI::Context->new($scope, sub {}, sub {});

    # Set via context stash
    $ctx->stash->set(user => 'bob');

    # Verify same data visible via PAGI::Stash on raw scope
    my $direct_stash = PAGI::Stash->new($scope);
    is($direct_stash->get('user'), 'bob', 'stash data shared with direct scope access');
};

done_testing;
```

- [ ] **Step 2: Run test to verify it passes**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/context/02-shared.t'`
Expected: All tests PASS (methods already implemented in Task 1)

- [ ] **Step 3: Commit**

```bash
git add t/context/02-shared.t
git commit -m "test: add shared method tests for PAGI::Context"
```

---

### Task 3: PAGI::Context::HTTP Subclass

**Files:**
- Modify: `lib/PAGI/Context/HTTP.pm`
- Create: `t/context/03-http.t`

- [ ] **Step 1: Write tests for HTTP-specific methods**

Create `t/context/03-http.t`:

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use PAGI::Context;

subtest 'HTTP context has correct methods' => sub {
    my $ctx = PAGI::Context->new(
        { type => 'http', method => 'GET', path => '/test', headers => [] },
        sub {}, sub {},
    );

    ok($ctx->can('request'), 'has request');
    ok($ctx->can('response'), 'has response');
    ok($ctx->can('method'), 'has method');

    # Should NOT have protocol-specific methods from other subclasses
    ok(!$ctx->can('websocket'), 'no websocket method');
    ok(!$ctx->can('sse'), 'no sse method');
};

subtest 'method accessor' => sub {
    my $ctx = PAGI::Context->new(
        { type => 'http', method => 'POST', path => '/', headers => [] },
        sub {}, sub {},
    );

    is($ctx->method, 'POST', 'method returns HTTP method');
};

subtest 'request accessor' => sub {
    my $receive = sub { Future->done({ type => 'http.request', body => '' }) };
    my $scope = {
        type    => 'http',
        method  => 'GET',
        path    => '/hello',
        headers => [['host', 'example.com']],
    };

    my $ctx = PAGI::Context->new($scope, $receive, sub {});
    my $req = $ctx->request;

    isa_ok($req, 'PAGI::Request');
    is($req->method, 'GET', 'request method works');
    is($req->path, '/hello', 'request path works');
    is($req->header('host'), 'example.com', 'request headers work');

    # Cached
    my $req2 = $ctx->request;
    ok($req == $req2, 'request is cached');
};

subtest 'response accessor' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $scope = {
        type    => 'http',
        method  => 'GET',
        path    => '/',
        headers => [],
    };

    my $ctx = PAGI::Context->new($scope, sub {}, $send);
    my $res = $ctx->response;

    isa_ok($res, 'PAGI::Response');

    # Cached
    my $res2 = $ctx->response;
    ok($res == $res2, 'response is cached');
};

subtest 'request and response share scope' => sub {
    my $scope = {
        type    => 'http',
        method  => 'GET',
        path    => '/',
        headers => [],
    };

    my $ctx = PAGI::Context->new($scope, sub {}, sub { Future->done });

    # Stash set via context is visible through request's scope
    $ctx->stash->set(user => 'alice');

    my $req_stash = PAGI::Stash->new($ctx->request);
    is($req_stash->get('user'), 'alice', 'stash flows from context to request');
};

subtest 'full HTTP round-trip' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $receive = sub { Future->done({ type => 'http.request', body => '' }) };

    my $scope = {
        type    => 'http',
        method  => 'GET',
        path    => '/test',
        headers => [],
    };

    my $ctx = PAGI::Context->new($scope, $receive, $send);

    (async sub {
        await $ctx->response->text('Hello from context!');
    })->()->get;

    is($sent[0]{status}, 200, 'response status sent');
    is($sent[1]{body}, 'Hello from context!', 'response body sent');
};

done_testing;
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/context/03-http.t'`
Expected: FAIL — HTTP context lacks `request`, `response`, `method`

- [ ] **Step 3: Implement PAGI::Context::HTTP**

Replace `lib/PAGI/Context/HTTP.pm`:

```perl
package PAGI::Context::HTTP;

use strict;
use warnings;

our @ISA = ('PAGI::Context');

=head1 NAME

PAGI::Context::HTTP - HTTP-specific context subclass

=head1 DESCRIPTION

Returned by C<< PAGI::Context->new(...) >> when C<< $scope->{type} >> is
C<'http'>. Adds lazy accessors for L<PAGI::Request> and L<PAGI::Response>,
plus an HTTP C<method> accessor.

Inherits all shared methods from L<PAGI::Context>.

=head1 METHODS

=head2 request

    my $req = $ctx->request;

Returns a L<PAGI::Request> instance. Lazy-constructed and cached.

=head2 response

    my $res = $ctx->response;

Returns a L<PAGI::Response> instance. Lazy-constructed and cached.

=head2 method

    my $method = $ctx->method;    # 'GET', 'POST', etc.

Returns the HTTP method from the scope.

=cut

sub request {
    my ($self) = @_;
    return $self->{_request} //= do {
        require PAGI::Request;
        PAGI::Request->new($self->{scope}, $self->{receive});
    };
}

sub response {
    my ($self) = @_;
    return $self->{_response} //= do {
        require PAGI::Response;
        PAGI::Response->new($self->{scope}, $self->{send});
    };
}

sub method { shift->{scope}{method} }

1;

__END__

=head1 SEE ALSO

L<PAGI::Context>, L<PAGI::Request>, L<PAGI::Response>

=cut
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/context/03-http.t'`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add lib/PAGI/Context/HTTP.pm t/context/03-http.t
git commit -m "feat: add PAGI::Context::HTTP with request, response, method"
```

---

### Task 4: PAGI::Context::WebSocket Subclass

**Files:**
- Modify: `lib/PAGI/Context/WebSocket.pm`
- Create: `t/context/04-websocket.t`

- [ ] **Step 1: Write tests for WebSocket-specific methods**

Create `t/context/04-websocket.t`:

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use PAGI::Context;

subtest 'WebSocket context has correct methods' => sub {
    my $ctx = PAGI::Context->new(
        { type => 'websocket', path => '/ws', headers => [] },
        sub {}, sub {},
    );

    ok($ctx->can('websocket'), 'has websocket');
    ok(!$ctx->can('request'), 'no request method');
    ok(!$ctx->can('response'), 'no response method');
    ok(!$ctx->can('method'), 'no method method');
    ok(!$ctx->can('sse'), 'no sse method');
};

subtest 'websocket accessor' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $receive = sub { Future->done({ type => 'websocket.disconnect' }) };

    my $scope = {
        type    => 'websocket',
        path    => '/ws/chat',
        headers => [['sec-websocket-protocol', 'chat']],
    };

    my $ctx = PAGI::Context->new($scope, $receive, $send);
    my $ws = $ctx->websocket;

    isa_ok($ws, 'PAGI::WebSocket');
    is($ws->path, '/ws/chat', 'websocket path works');

    # Cached
    my $ws2 = $ctx->websocket;
    ok($ws == $ws2, 'websocket is cached');
};

subtest 'shared methods work on WebSocket context' => sub {
    my $scope = {
        type    => 'websocket',
        path    => '/ws',
        headers => [['authorization', 'Bearer token123']],
    };

    my $ctx = PAGI::Context->new($scope, sub {}, sub {});

    is($ctx->type, 'websocket', 'type accessor');
    is($ctx->path, '/ws', 'path accessor');
    is($ctx->header('authorization'), 'Bearer token123', 'header lookup');
    ok($ctx->is_websocket, 'is_websocket true');
    ok(!$ctx->is_http, 'is_http false');

    $ctx->stash->set(room => 'general');
    is($ctx->stash->get('room'), 'general', 'stash works');
};

subtest 'WebSocket accept round-trip' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $receive = sub { Future->done({ type => 'websocket.disconnect' }) };

    my $scope = {
        type    => 'websocket',
        path    => '/ws',
        headers => [],
    };

    my $ctx = PAGI::Context->new($scope, $receive, $send);

    (async sub {
        await $ctx->websocket->accept;
    })->()->get;

    is($sent[0]{type}, 'websocket.accept', 'accept event sent');
};

done_testing;
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/context/04-websocket.t'`
Expected: FAIL — WebSocket context lacks `websocket` method

- [ ] **Step 3: Implement PAGI::Context::WebSocket**

Replace `lib/PAGI/Context/WebSocket.pm`:

```perl
package PAGI::Context::WebSocket;

use strict;
use warnings;

our @ISA = ('PAGI::Context');

=head1 NAME

PAGI::Context::WebSocket - WebSocket-specific context subclass

=head1 DESCRIPTION

Returned by C<< PAGI::Context->new(...) >> when C<< $scope->{type} >> is
C<'websocket'>. Adds a lazy accessor for L<PAGI::WebSocket>.

Inherits all shared methods from L<PAGI::Context>.

=head1 METHODS

=head2 websocket

    my $ws = $ctx->websocket;

Returns a L<PAGI::WebSocket> instance. Lazy-constructed and cached.

=cut

sub websocket {
    my ($self) = @_;
    return $self->{_websocket} //= do {
        require PAGI::WebSocket;
        PAGI::WebSocket->new($self->{scope}, $self->{receive}, $self->{send});
    };
}

1;

__END__

=head1 SEE ALSO

L<PAGI::Context>, L<PAGI::WebSocket>

=cut
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/context/04-websocket.t'`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add lib/PAGI/Context/WebSocket.pm t/context/04-websocket.t
git commit -m "feat: add PAGI::Context::WebSocket with websocket accessor"
```

---

### Task 5: PAGI::Context::SSE Subclass

**Files:**
- Modify: `lib/PAGI/Context/SSE.pm`
- Create: `t/context/05-sse.t`

- [ ] **Step 1: Write tests for SSE-specific methods**

Create `t/context/05-sse.t`:

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use PAGI::Context;

subtest 'SSE context has correct methods' => sub {
    my $ctx = PAGI::Context->new(
        { type => 'sse', path => '/events', headers => [] },
        sub {}, sub {},
    );

    ok($ctx->can('sse'), 'has sse');
    ok(!$ctx->can('request'), 'no request method');
    ok(!$ctx->can('response'), 'no response method');
    ok(!$ctx->can('method'), 'no method method');
    ok(!$ctx->can('websocket'), 'no websocket method');
};

subtest 'sse accessor' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $receive = sub { Future->done({ type => 'sse.disconnect' }) };

    my $scope = {
        type    => 'sse',
        path    => '/events/news',
        headers => [['accept', 'text/event-stream']],
    };

    my $ctx = PAGI::Context->new($scope, $receive, $send);
    my $sse = $ctx->sse;

    isa_ok($sse, 'PAGI::SSE');
    is($sse->path, '/events/news', 'sse path works');

    # Cached
    my $sse2 = $ctx->sse;
    ok($sse == $sse2, 'sse is cached');
};

subtest 'shared methods work on SSE context' => sub {
    my $scope = {
        type    => 'sse',
        path    => '/events',
        headers => [['last-event-id', '42']],
    };

    my $ctx = PAGI::Context->new($scope, sub {}, sub {});

    is($ctx->type, 'sse', 'type accessor');
    is($ctx->path, '/events', 'path accessor');
    is($ctx->header('last-event-id'), '42', 'header lookup');
    ok($ctx->is_sse, 'is_sse true');
    ok(!$ctx->is_http, 'is_http false');
    ok(!$ctx->is_websocket, 'is_websocket false');

    $ctx->stash->set(channel => 'news');
    is($ctx->stash->get('channel'), 'news', 'stash works');
};

subtest 'SSE send event round-trip' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $receive = sub { Future->done({ type => 'sse.disconnect' }) };

    my $scope = {
        type    => 'sse',
        path    => '/events',
        headers => [],
    };

    my $ctx = PAGI::Context->new($scope, $receive, $send);

    (async sub {
        await $ctx->sse->send_event(event => 'ping', data => { ts => 1 });
    })->()->get;

    ok(scalar @sent > 0, 'SSE sent events');
};

done_testing;
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/context/05-sse.t'`
Expected: FAIL — SSE context lacks `sse` method

- [ ] **Step 3: Implement PAGI::Context::SSE**

Replace `lib/PAGI/Context/SSE.pm`:

```perl
package PAGI::Context::SSE;

use strict;
use warnings;

our @ISA = ('PAGI::Context');

=head1 NAME

PAGI::Context::SSE - SSE-specific context subclass

=head1 DESCRIPTION

Returned by C<< PAGI::Context->new(...) >> when C<< $scope->{type} >> is
C<'sse'>. Adds a lazy accessor for L<PAGI::SSE>.

Inherits all shared methods from L<PAGI::Context>.

=head1 METHODS

=head2 sse

    my $sse = $ctx->sse;

Returns a L<PAGI::SSE> instance. Lazy-constructed and cached.

=cut

sub sse {
    my ($self) = @_;
    return $self->{_sse} //= do {
        require PAGI::SSE;
        PAGI::SSE->new($self->{scope}, $self->{receive}, $self->{send});
    };
}

1;

__END__

=head1 SEE ALSO

L<PAGI::Context>, L<PAGI::SSE>

=cut
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/context/05-sse.t'`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add lib/PAGI/Context/SSE.pm t/context/05-sse.t
git commit -m "feat: add PAGI::Context::SSE with sse accessor"
```

---

### Task 6: Extension / Subclassing

**Files:**
- Create: `t/context/06-extension.t`

- [ ] **Step 1: Write tests for subclassing and custom type maps**

Create `t/context/06-extension.t`:

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use PAGI::Context;

subtest 'custom _type_map adds new protocol' => sub {
    {
        package TestExt::Context;
        our @ISA = ('PAGI::Context');

        sub _type_map {
            my ($class) = @_;
            return {
                %{ $class->SUPER::_type_map },
                grpc => 'TestExt::Context::GRPC',
            };
        }

        package TestExt::Context::GRPC;
        our @ISA = ('PAGI::Context');

        sub grpc_method { shift->{scope}{grpc_method} }
    }

    my $ctx = TestExt::Context->new(
        { type => 'grpc', grpc_method => 'users.List', headers => [] },
        sub {}, sub {},
    );

    isa_ok($ctx, 'PAGI::Context');
    isa_ok($ctx, 'TestExt::Context::GRPC');
    is($ctx->grpc_method, 'users.List', 'custom method works');
    is($ctx->type, 'grpc', 'type accessor works');
    is($ctx->path, undef, 'path is undef (no path in gRPC)');

    # Standard types still work
    my $http = TestExt::Context->new(
        { type => 'http', method => 'GET', path => '/', headers => [] },
        sub {}, sub {},
    );
    isa_ok($http, 'PAGI::Context::HTTP');
};

subtest 'custom _type_map replaces built-in type' => sub {
    {
        package TestReplace::Context;
        our @ISA = ('PAGI::Context');

        sub _type_map {
            my ($class) = @_;
            return {
                %{ $class->SUPER::_type_map },
                http => 'TestReplace::Context::HTTP',
            };
        }

        package TestReplace::Context::HTTP;
        our @ISA = ('PAGI::Context::HTTP');

        sub current_user {
            my ($self) = @_;
            return $self->stash->get('current_user', undef);
        }
    }

    my $ctx = TestReplace::Context->new(
        { type => 'http', method => 'GET', path => '/', headers => [] },
        sub {}, sub {},
    );

    isa_ok($ctx, 'PAGI::Context');
    isa_ok($ctx, 'PAGI::Context::HTTP');
    isa_ok($ctx, 'TestReplace::Context::HTTP');
    ok($ctx->can('request'), 'inherits HTTP request method');
    ok($ctx->can('current_user'), 'has custom method');
    is($ctx->current_user, undef, 'custom method works');
};

subtest 'custom _resolve_class overrides resolution logic' => sub {
    {
        package TestResolve::Context;
        our @ISA = ('PAGI::Context');

        sub _resolve_class {
            my ($class, $scope) = @_;
            # Route WebSocket with specific subprotocol to custom class
            if (($scope->{type} // '') eq 'websocket') {
                for my $pair (@{$scope->{headers} // []}) {
                    if (lc($pair->[0]) eq 'sec-websocket-protocol'
                        && $pair->[1] eq 'jsonrpc') {
                        return 'TestResolve::Context::JsonRPC';
                    }
                }
            }
            return $class->SUPER::_resolve_class($scope);
        }

        package TestResolve::Context::JsonRPC;
        our @ISA = ('PAGI::Context::WebSocket');

        sub is_jsonrpc { 1 }
    }

    my $jsonrpc = TestResolve::Context->new(
        {
            type    => 'websocket',
            path    => '/rpc',
            headers => [['sec-websocket-protocol', 'jsonrpc']],
        },
        sub {}, sub {},
    );

    isa_ok($jsonrpc, 'TestResolve::Context::JsonRPC');
    isa_ok($jsonrpc, 'PAGI::Context::WebSocket');
    isa_ok($jsonrpc, 'PAGI::Context');
    ok($jsonrpc->is_jsonrpc, 'custom method available');
    ok($jsonrpc->can('websocket'), 'inherits websocket accessor');

    # Non-jsonrpc WebSocket still resolves normally
    my $plain_ws = TestResolve::Context->new(
        { type => 'websocket', path => '/ws', headers => [] },
        sub {}, sub {},
    );
    isa_ok($plain_ws, 'PAGI::Context::WebSocket');
    ok(!$plain_ws->can('is_jsonrpc'), 'plain WS does not have custom method');
};

subtest 'unknown type from custom factory falls back to HTTP' => sub {
    my $ctx = PAGI::Context->new(
        { type => 'carrier_pigeon', headers => [] },
        sub {}, sub {},
    );
    isa_ok($ctx, 'PAGI::Context::HTTP');
};

done_testing;
```

- [ ] **Step 2: Run test to verify it passes**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/context/06-extension.t'`
Expected: All tests PASS (extensibility is inherent in the design)

- [ ] **Step 3: Commit**

```bash
git add t/context/06-extension.t
git commit -m "test: add extension and subclassing tests for PAGI::Context"
```

---

### Task 7: Endpoint::Router Integration — context_class + Handler Wrappers

This is the most complex task. It modifies the router to inject `$ctx` instead of protocol objects.

**Files:**
- Modify: `lib/PAGI/Endpoint/Router.pm`
- Create: `t/context/07-router.t`
- Modify: `t/endpoint-router.t`

- [ ] **Step 1: Write integration tests for Context-based router**

Create `t/context/07-router.t`:

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;
use PAGI::Stash;

# Load the modules
require PAGI::Endpoint::Router;
require PAGI::Context;

subtest 'context_class defaults to PAGI::Context' => sub {
    my $router = PAGI::Endpoint::Router->new;
    is($router->context_class, 'PAGI::Context', 'default context class');
};

subtest 'HTTP handler receives $ctx' => sub {
    {
        package TestCtx::HTTP;
        use parent 'PAGI::Endpoint::Router';
        use Future::AsyncAwait;

        sub routes {
            my ($self, $r) = @_;
            $r->get('/hello' => 'say_hello');
            $r->get('/users/:id' => 'get_user');
        }

        async sub say_hello {
            my ($self, $ctx) = @_;
            die "Expected PAGI::Context::HTTP"
                unless $ctx->isa('PAGI::Context::HTTP');
            await $ctx->response->text('Hello!');
        }

        async sub get_user {
            my ($self, $ctx) = @_;
            my $id = $ctx->request->path_param('id');
            await $ctx->response->json({ id => $id });
        }
    }

    my $app = TestCtx::HTTP->to_app;

    # Test /hello
    (async sub {
        my @sent;
        my $send = sub { push @sent, $_[0]; Future->done };
        my $receive = sub { Future->done({ type => 'http.request', body => '' }) };

        await $app->(
            { type => 'http', method => 'GET', path => '/hello', headers => [] },
            $receive, $send,
        );

        is($sent[0]{status}, 200, '/hello returns 200');
        is($sent[1]{body}, 'Hello!', '/hello returns Hello!');
    })->()->get;

    # Test /users/:id
    (async sub {
        my @sent;
        my $send = sub { push @sent, $_[0]; Future->done };
        my $receive = sub { Future->done({ type => 'http.request', body => '' }) };

        await $app->(
            { type => 'http', method => 'GET', path => '/users/42', headers => [] },
            $receive, $send,
        );

        is($sent[0]{status}, 200, '/users/42 returns 200');
        like($sent[1]{body}, qr/"id".*"42"/, 'body contains user id');
    })->()->get;
};

subtest 'WebSocket handler receives $ctx' => sub {
    {
        package TestCtx::WS;
        use parent 'PAGI::Endpoint::Router';
        use Future::AsyncAwait;

        sub routes {
            my ($self, $r) = @_;
            $r->websocket('/ws/echo/:room' => 'echo_handler');
        }

        async sub echo_handler {
            my ($self, $ctx) = @_;
            die "Expected PAGI::Context::WebSocket"
                unless $ctx->isa('PAGI::Context::WebSocket');

            my $ws = $ctx->websocket;
            my $room = $ws->path_param('room');
            die "Expected room param" unless $room eq 'test-room';

            await $ws->accept;
        }
    }

    my $app = TestCtx::WS->to_app;

    (async sub {
        my @sent;
        my $send = sub { push @sent, $_[0]; Future->done };
        my $receive = sub { Future->done({ type => 'websocket.disconnect' }) };

        await $app->(
            { type => 'websocket', path => '/ws/echo/test-room', headers => [] },
            $receive, $send,
        );

        is($sent[0]{type}, 'websocket.accept', 'WebSocket was accepted');
    })->()->get;
};

subtest 'SSE handler receives $ctx' => sub {
    {
        package TestCtx::SSE;
        use parent 'PAGI::Endpoint::Router';
        use Future::AsyncAwait;

        sub routes {
            my ($self, $r) = @_;
            $r->sse('/events/:channel' => 'events_handler');
        }

        async sub events_handler {
            my ($self, $ctx) = @_;
            die "Expected PAGI::Context::SSE"
                unless $ctx->isa('PAGI::Context::SSE');

            my $sse = $ctx->sse;
            my $channel = $sse->path_param('channel');
            die "Expected channel param" unless $channel eq 'news';

            await $sse->send_event(event => 'connected', data => { channel => $channel });
        }
    }

    my $app = TestCtx::SSE->to_app;

    (async sub {
        my @sent;
        my $send = sub { push @sent, $_[0]; Future->done };
        my $receive = sub { Future->done({ type => 'sse.disconnect' }) };

        await $app->(
            { type => 'sse', path => '/events/news', headers => [] },
            $receive, $send,
        );

        ok(scalar @sent > 0, 'SSE sent events');
    })->()->get;
};

subtest 'middleware receives $ctx' => sub {
    {
        package TestCtx::Middleware;
        use parent 'PAGI::Endpoint::Router';
        use Future::AsyncAwait;

        our $auth_called = 0;
        our $handler_saw_user;

        sub routes {
            my ($self, $r) = @_;
            $r->get('/protected' => ['require_auth'] => 'protected_handler');
        }

        async sub require_auth {
            my ($self, $ctx, $next) = @_;
            $auth_called = 1;

            my $token = $ctx->header('authorization');
            if ($token && $token eq 'Bearer valid') {
                $ctx->stash->set(user => { id => 1 });
                await $next->();
            } else {
                await $ctx->response->status(401)->json({ error => 'Unauthorized' });
            }
        }

        async sub protected_handler {
            my ($self, $ctx) = @_;
            $handler_saw_user = $ctx->stash->get('user');
            await $ctx->response->json({ user_id => $handler_saw_user->{id} });
        }
    }

    my $app = TestCtx::Middleware->to_app;

    # Without auth
    (async sub {
        my @sent;
        $TestCtx::Middleware::auth_called = 0;

        await $app->(
            { type => 'http', method => 'GET', path => '/protected', headers => [] },
            sub { Future->done({ type => 'http.request', body => '' }) },
            sub { push @sent, $_[0]; Future->done },
        );

        ok($TestCtx::Middleware::auth_called, 'auth middleware called');
        is($sent[0]{status}, 401, 'returns 401 without auth');
    })->()->get;

    # With auth
    (async sub {
        my @sent;
        $TestCtx::Middleware::auth_called = 0;

        await $app->(
            {
                type    => 'http',
                method  => 'GET',
                path    => '/protected',
                headers => [['authorization', 'Bearer valid']],
            },
            sub { Future->done({ type => 'http.request', body => '' }) },
            sub { push @sent, $_[0]; Future->done },
        );

        is($sent[0]{status}, 200, 'returns 200 with auth');
        is($TestCtx::Middleware::handler_saw_user->{id}, 1, 'handler sees user from middleware');
    })->()->get;
};

subtest 'state accessible via context' => sub {
    {
        package TestCtx::State;
        use parent 'PAGI::Endpoint::Router';
        use Future::AsyncAwait;

        our $state_value;

        sub routes {
            my ($self, $r) = @_;
            $self->state->{db} = 'connected';
            $r->get('/test' => 'test_handler');
        }

        async sub test_handler {
            my ($self, $ctx) = @_;
            $state_value = $ctx->state->{db};
            await $ctx->response->text('ok');
        }
    }

    my $app = TestCtx::State->to_app;

    (async sub {
        my @sent;
        await $app->(
            { type => 'http', method => 'GET', path => '/test', headers => [] },
            sub { Future->done({ type => 'http.request', body => '' }) },
            sub { push @sent, $_[0]; Future->done },
        );

        is($TestCtx::State::state_value, 'connected', 'state accessible via $ctx->state');
    })->()->get;
};

subtest 'custom context_class' => sub {
    {
        package TestCustomCtx::Context;
        our @ISA = ('PAGI::Context');

        sub _type_map {
            my ($class) = @_;
            return {
                %{ $class->SUPER::_type_map },
                http => 'TestCustomCtx::Context::HTTP',
            };
        }

        package TestCustomCtx::Context::HTTP;
        our @ISA = ('PAGI::Context::HTTP');

        sub custom_method { 'custom' }

        package TestCustomCtx::App;
        use parent 'PAGI::Endpoint::Router';
        use Future::AsyncAwait;

        our $custom_method_result;

        sub context_class { 'TestCustomCtx::Context' }

        sub routes {
            my ($self, $r) = @_;
            $r->get('/test' => 'test_handler');
        }

        async sub test_handler {
            my ($self, $ctx) = @_;
            $custom_method_result = $ctx->custom_method;
            await $ctx->response->text('ok');
        }
    }

    my $app = TestCustomCtx::App->to_app;

    (async sub {
        my @sent;
        await $app->(
            { type => 'http', method => 'GET', path => '/test', headers => [] },
            sub { Future->done({ type => 'http.request', body => '' }) },
            sub { push @sent, $_[0]; Future->done },
        );

        is($TestCustomCtx::App::custom_method_result, 'custom',
           'custom context_class used');
    })->()->get;
};

done_testing;
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/context/07-router.t'`
Expected: FAIL — router still injects `($req, $res)` not `($ctx)`

- [ ] **Step 3: Modify Endpoint::Router to inject $ctx**

Modify `lib/PAGI/Endpoint/Router.pm`. Changes:

1. Add `context_class` method that defaults to `'PAGI::Context'`
2. Update `_wrap_http_handler` to construct and inject `$ctx`
3. Update `_wrap_websocket_handler` to construct and inject `$ctx`
4. Update `_wrap_sse_handler` to construct and inject `$ctx`
5. Update `_wrap_middleware` to inject `($ctx, $next)` instead of `($req, $res, $next)`

Add `context_class` method to `PAGI::Endpoint::Router` (after `state` method):

```perl
sub context_class { 'PAGI::Context' }
```

Pass `context_class` into the RouteBuilder via `_build_routes`. Change `_build_routes`:

```perl
sub _build_routes {
    my ($self, $r) = @_;
    my $wrapper = PAGI::Endpoint::Router::RouteBuilder->new($self, $r);
    $self->routes($wrapper);
}
```

The RouteBuilder already receives `$self` (the endpoint) as `$self->{endpoint}`. To access the context class, the wrapper methods call `$self->{endpoint}->context_class`.

Update `_wrap_http_handler` in `PAGI::Endpoint::Router::RouteBuilder`:

```perl
sub _wrap_http_handler {
    my ($self, $handler) = @_;

    my $endpoint = $self->{endpoint};
    my $context_class = $endpoint->context_class;

    if (!ref($handler)) {
        my $method_name = $handler;
        my $method = $endpoint->can($method_name)
            or die "No such method: $method_name in " . ref($endpoint);

        return async sub {
            my ($scope, $receive, $send) = @_;

            require PAGI::Context;

            my $ctx = $context_class->new($scope, $receive, $send);

            await $endpoint->$method($ctx);
        };
    }

    return async sub {
        my ($scope, $receive, $send) = @_;

        require PAGI::Context;

        my $ctx = $context_class->new($scope, $receive, $send);

        await $handler->($ctx);
    };
}
```

Update `_wrap_websocket_handler`:

```perl
sub _wrap_websocket_handler {
    my ($self, $handler) = @_;

    my $endpoint = $self->{endpoint};
    my $context_class = $endpoint->context_class;

    if (!ref($handler)) {
        my $method_name = $handler;
        my $method = $endpoint->can($method_name)
            or die "No such method: $method_name";

        return async sub {
            my ($scope, $receive, $send) = @_;

            require PAGI::Context;

            my $ctx = $context_class->new($scope, $receive, $send);

            await $endpoint->$method($ctx);
        };
    }

    return async sub {
        my ($scope, $receive, $send) = @_;

        require PAGI::Context;

        my $ctx = $context_class->new($scope, $receive, $send);

        await $handler->($ctx);
    };
}
```

Update `_wrap_sse_handler`:

```perl
sub _wrap_sse_handler {
    my ($self, $handler) = @_;

    my $endpoint = $self->{endpoint};
    my $context_class = $endpoint->context_class;

    if (!ref($handler)) {
        my $method_name = $handler;
        my $method = $endpoint->can($method_name)
            or die "No such method: $method_name";

        return async sub {
            my ($scope, $receive, $send) = @_;

            require PAGI::Context;

            my $ctx = $context_class->new($scope, $receive, $send);

            await $endpoint->$method($ctx);
        };
    }

    return async sub {
        my ($scope, $receive, $send) = @_;

        require PAGI::Context;

        my $ctx = $context_class->new($scope, $receive, $send);

        await $handler->($ctx);
    };
}
```

Update `_wrap_middleware`:

```perl
sub _wrap_middleware {
    my ($self, $mw) = @_;

    my $endpoint = $self->{endpoint};
    my $context_class = $endpoint->context_class;

    if (!ref($mw)) {
        my $method = $endpoint->can($mw)
            or die "No such middleware method: $mw";

        return async sub {
            my ($scope, $receive, $send, $next) = @_;

            require PAGI::Context;

            my $ctx = $context_class->new($scope, $receive, $send);

            await $endpoint->$method($ctx, $next);
        };
    }

    return $mw;
}
```

- [ ] **Step 4: Run context/07-router tests**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/context/07-router.t'`
Expected: All tests PASS

- [ ] **Step 5: Update existing t/endpoint-router.t handler signatures**

The existing test file at `t/endpoint-router.t` has inline endpoint classes
whose handlers use the old `($req, $res)` / `($ws)` / `($sse)` signatures.
Update all handler signatures to use `($ctx)`.

Changes to make:

**TestApp::HTTP** — `say_hello` and `get_user`:

```perl
async sub say_hello {
    my ($self, $ctx) = @_;
    await $ctx->response->text('Hello!');
}

async sub get_user {
    my ($self, $ctx) = @_;
    my $id = $ctx->request->path_param('id');
    await $ctx->response->json({ id => $id });
}
```

**TestApp::WS** — `echo_handler`:

```perl
async sub echo_handler {
    my ($self, $ctx) = @_;

    my $ws = $ctx->websocket;
    die "Expected PAGI::WebSocket" unless $ws->isa('PAGI::WebSocket');

    my $room = $ws->path_param('room');
    die "Expected room param" unless $room eq 'test-room';

    await $ws->accept;
}
```

**TestApp::SSE** — `events_handler`:

```perl
async sub events_handler {
    my ($self, $ctx) = @_;

    my $sse = $ctx->sse;
    die "Expected PAGI::SSE" unless $sse->isa('PAGI::SSE');

    my $channel = $sse->path_param('channel');
    die "Expected channel param" unless $channel eq 'news';

    await $sse->send_event(event => 'connected', data => { channel => $channel });
}
```

**TestApp::State** — `test_handler`:

```perl
async sub test_handler {
    my ($self, $ctx) = @_;
    $state_value = $self->state->{db};
    $req_state_value = $ctx->state->{db};
    await $ctx->response->text('ok');
}
```

Note: Change the var name from `$req_state_value` to reflect it comes from ctx now. The test assertion `is($TestApp::State::req_state_value, 'connected', ...)` message should update to `'state accessible via $ctx->state'`.

**TestApp::Middleware** — `require_auth`, `log_request`, `public_handler`, `protected_handler`:

```perl
async sub require_auth {
    my ($self, $ctx, $next) = @_;
    $auth_called = 1;

    my $token = $ctx->header('authorization');
    if ($token && $token eq 'Bearer valid') {
        $ctx->stash->set(user => { id => 1 });
        await $next->();
    } else {
        await $ctx->response->status(401)->json({ error => 'Unauthorized' });
    }
}

async sub log_request {
    my ($self, $ctx, $next) = @_;
    $log_called = 1;
    await $next->();
}

async sub public_handler {
    my ($self, $ctx) = @_;
    await $ctx->response->text('public');
}

async sub protected_handler {
    my ($self, $ctx) = @_;
    my $user = $ctx->stash->get('user');
    await $ctx->response->json({ user_id => $user->{id} });
}
```

**TestApp::StashFlow** — `set_user`, `check_user`:

```perl
async sub set_user {
    my ($self, $ctx, $next) = @_;
    $ctx->stash->set(user => 'alice');
    await $next->();
}

async sub check_user {
    my ($self, $ctx) = @_;
    $handler_saw_user = $ctx->stash->get('user');
    await $ctx->response->text('ok');
}
```

- [ ] **Step 6: Run both router test files**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/endpoint-router.t t/context/07-router.t'`
Expected: All tests PASS

- [ ] **Step 7: Commit**

```bash
git add lib/PAGI/Endpoint/Router.pm t/context/07-router.t t/endpoint-router.t
git commit -m "feat: integrate PAGI::Context into Endpoint::Router

Router now injects \$ctx instead of (\$req, \$res) / (\$ws) / (\$sse).
Adds context_class method for custom context subclasses."
```

---

### Task 8: Update Examples

**Files:**
- Modify: `examples/endpoint-demo/app.pl`
- Modify: `examples/endpoint-router-demo/lib/MyApp/Main.pm`
- Modify: `examples/endpoint-router-demo/lib/MyApp/API.pm`

- [ ] **Step 1: Check which example files use Endpoint::Router handler signatures**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && grep -rn "my.*\$self.*\$req.*\$res" examples/ && grep -rn "my.*\$self.*\$ws" examples/ && grep -rn "my.*\$self.*\$sse" examples/'`

Identify all files with old handler signatures and update them. For each file:
- Change `my ($self, $req, $res) = @_` to `my ($self, $ctx) = @_`
- Change `$req->method` to `$ctx->request->method` (or `$ctx->method` for HTTP)
- Change `$res->json(...)` to `$ctx->response->json(...)`
- Change `my ($self, $ws) = @_` to `my ($self, $ctx) = @_; my $ws = $ctx->websocket;`
- Change `my ($self, $sse) = @_` to `my ($self, $ctx) = @_; my $sse = $ctx->sse;`
- Change middleware `my ($self, $req, $res, $next)` to `my ($self, $ctx, $next)`

- [ ] **Step 2: Verify examples still parse**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && perl -Ilib -c examples/endpoint-demo/app.pl && perl -Ilib -Iexamples/endpoint-router-demo/lib -c examples/endpoint-router-demo/lib/MyApp/Main.pm'`
Expected: `syntax OK` for each file

- [ ] **Step 3: Commit**

```bash
git add examples/
git commit -m "docs: update examples to use PAGI::Context handler signatures"
```

---

### Task 9: Full Test Suite + Final Review

**Files:** None (validation only)

- [ ] **Step 1: Run the full context test suite**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && prove -l t/context/'`
Expected: All tests PASS

- [ ] **Step 2: Run the full project test suite**

Run: `bash -c 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.40.0@default && RELEASE_TESTING=1 prove -l t/'`
Expected: Same failures as before this work (t/31-memory-leak.t, t/42-file-response.t, t/app-file.t are pre-existing). No new failures.

- [ ] **Step 3: Final review checklist**

Verify:
- `$ctx->isa('PAGI::Context')` returns true for all subclasses
- `$ctx->can('request')` returns false on WebSocket/SSE contexts
- `$ctx->can('websocket')` returns false on HTTP/SSE contexts
- `$ctx->can('sse')` returns false on HTTP/WebSocket contexts
- Stash set via `$ctx->stash` is visible via `PAGI::Stash->new($scope)`
- No new dependencies added (check no new `use` of external CPAN modules)
- POD documentation present on all new modules
- All new files have `use strict; use warnings;`

- [ ] **Step 4: Commit any fixes from review, then final commit message**

If no fixes needed, skip this step. Otherwise:

```bash
git add -A
git commit -m "fix: address issues found in final review"
```
