# Worker Pool Example

Demonstrates `$c->run_blocking()` for running blocking operations in worker
processes without blocking the event loop.

## Use Cases

- **Database queries**: DBI/DBD::* are blocking
- **File I/O**: Large file reads/writes
- **CPU-intensive**: Heavy computations
- **Legacy code**: Non-async libraries
- **External commands**: System calls, shell commands

## Running

```bash
pagi-server --port 3000 examples/simple-20-worker-pool/app.pl
```

## Endpoints

| Endpoint | Description |
|----------|-------------|
| `/` | Home page with links |
| `/compute/:n` | Sum 1 to n in worker |
| `/sleep/:seconds` | Blocking sleep |
| `/file-stats` | Get file statistics |
| `/fibonacci/:n` | Compute Fibonacci number |
| `/non-blocking` | Normal handler for comparison |

## Configuration

```perl
my $app = PAGI::Simple->new(
    workers => {
        max_workers  => 4,    # Max concurrent workers
        min_workers  => 1,    # Keep-alive workers
        idle_timeout => 60,   # Kill idle workers (seconds)
    },
);
```

## Passing Arguments to Workers

Pass data after the coderef, receive via `@_`:

```perl
my $id = $c->path_params->{id};
my $filters = { status => 'active', limit => 10 };

my $result = await $c->run_blocking(sub {
    my ($user_id, $opts) = @_;
    my $dbh = DBI->connect($ENV{DB_DSN});
    return $dbh->selectall_arrayref(
        "SELECT * FROM orders WHERE user_id = ? LIMIT ?",
        { Slice => {} },
        $user_id, $opts->{limit}
    );
}, $id, $filters);
```

## Important: Use @_, Not Signatures

Due to a B::Deparse limitation, subroutine signatures do NOT work:

```perl
# BAD - signatures don't work
await $c->run_blocking(sub ($id, $name) {
    return "$id: $name";
}, $id, $name);

# GOOD - use @_ style
await $c->run_blocking(sub {
    my ($id, $name) = @_;
    return "$id: $name";
}, $id, $name);
```

## What Can Be Passed

Arguments must be serializable by Sereal:

- Scalars (strings, numbers)
- Array references
- Hash references
- Nested structures

Cannot pass:
- Coderefs
- Filehandles
- Database connections
- Complex objects with internal state

## Error Handling

Exceptions in workers propagate back as Future failures:

```perl
my $result = eval {
    await $c->run_blocking(sub {
        die "Something went wrong" if $error;
        return compute_result();
    });
};

if ($@) {
    $c->status(500)->json({ error => $@ });
    return;
}

$c->json($result);
```

## When to Use Workers

Use `run_blocking` when you have blocking operations:

- DBI database queries
- File::Slurp or similar blocking file operations
- LWP::UserAgent HTTP requests
- Image processing with GD or Imager
- PDF generation
- External command execution (backticks, system())

## When NOT to Use Workers

Don't use workers for operations that already support async:

- Net::Async::HTTP (use directly)
- IO::Async file operations (use PAGI::Util::AsyncFile)
- Async database drivers (DBD::mysql async, Mojo::Pg, etc.)

Using workers adds IPC overhead - only use when necessary.
