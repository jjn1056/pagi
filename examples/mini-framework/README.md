# A web framework built on PAGI — in ~50 lines

Routing, path parameters, and proper async dispatch — the heart of every web
framework — as a thin layer over raw PAGI. The entire framework is the `Nano`
package at the top of [`app.pl`](app.pl); everything below it is an ordinary
application that never touches the protocol directly.

This example exists to make one point concrete: **PAGI is a foundation.** The
protocol is small and stable, and a framework is just an *optional* layer you
can build (or borrow) on top of it.

## Run it

From the PAGI root, using `pagi-server` from the `PAGI-Server` distribution:

```bash
pagi-server --app examples/mini-framework/app.pl --port 5000

curl localhost:5000/                 # Hello from a web framework built on PAGI!
curl localhost:5000/hello/ada        # Hello, ada!
curl localhost:5000/slow/2           # waits 2s, then replies
curl localhost:5000/nope             # 404 Not Found
```

And the part that matters — fire two slow requests at once:

```bash
time ( curl -s localhost:5000/slow/2 & curl -s localhost:5000/slow/2 & wait )
# real  ~2.0s   -- both finished together, not 4s.
```

Two requests that each "take" two seconds complete in two seconds total. The
async handler `await`s without blocking anyone else. That is the whole reason
PAGI exists, and the framework got it for free.

## The whole framework

A PAGI application is just an `async sub` that receives three things — the
connection `$scope`, and `$receive` / `$send` coderefs. Everything a framework
does is build a friendlier interface over those three values. `Nano` has
exactly three responsibilities:

1. **Route registration.** `get`/`post`/`put`/`patch`/`delete` are defined in
   one loop. Each compiles a path like `/users/:id` into a regex that captures
   the `:params`.

2. **Dispatch** (`to_app`). This returns the actual PAGI app coderef: it walks
   the routes, matches method + path, fills in the captured params, and calls
   your handler. Handlers may be plain subs (return a string) or `async` subs
   (return a Future) — it `await`s the Future when there is one, which is what
   makes `/slow/:secs` non-blocking.

3. **Response** (`_reply`). Turns a string into the two events PAGI wants:
   `http.response.start` then `http.response.body`.

That's it. No XS, no magic, and nothing tied to a particular event loop — the
same app runs unchanged on any conforming PAGI server.

## Why this matters

You just watched routing, path parameters, and correct async concurrency happen
in about fifty lines of plain Perl — nothing newer than 5.18, no XS, no magic.
Scale that thought up:

- A real framework adds *more* of the same kind of layering — it is not a
  different category of thing.
- You don't have to build all of it from scratch. The `PAGI-Tools`
  distribution already ships a production router, middleware, and
  request/response objects you can assemble.
- Perl's async web world is missing the frameworks that ASGI gave Python
  (FastAPI, Starlette, Django-async). The foundation for them is done. This
  example is the invitation to go build one.

## What `Nano` leaves out (on purpose)

Kept tiny to stay readable. A real framework — or your assembly of `PAGI-Tools`
parts — would add:

- **Request/response objects** instead of raw hashes and strings — see
  `PAGI::Request` and `PAGI::Response` in `PAGI-Tools`.
- **`405 Method Not Allowed`** (Nano returns `404` when only the method
  differs) and **`HEAD`** handling.
- **Content negotiation, JSON encoding, body parsing, cookies, sessions** —
  the `PAGI::Middleware::*` and `PAGI::App::*` suites cover these.
- **Middleware** (a wrapping layer around the app) and **error handling**.
- A faster matcher than a linear scan once you have many routes — see
  `PAGI::App::Router`.

None of these are magic; each is another small layer over the same protocol.

## See also

- [`PAGI::Tutorial`](../../lib/PAGI/Tutorial.pod) — learn the protocol this is built on
- `PAGI::Spec` — the formal specification
- `PAGI-Tools` — routers, middleware, and request/response helpers to build with
