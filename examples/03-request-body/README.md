# 03 – Request Body Echo

Reads all `http.request` events, concatenates the body, and echoes it back. Demonstrates:
- Looping over `http.request` events with `more` handling.
- Building a response that reflects information from the request.

## Quick Start

**1. Start the server:**

```bash
pagi-server --app examples/03-request-body/app.pl --port 5000
```

**2. Demo with curl:**

```bash
# POST data and see it echoed back
curl -X POST http://localhost:5000/ -d "Hello, PAGI!"
# => You sent: Hello, PAGI!

# POST JSON data
curl -X POST http://localhost:5000/ \
  -H "Content-Type: application/json" \
  -d '{"message":"test"}'
# => You sent: {"message":"test"}

# POST from a file
echo "File contents here" | curl -X POST http://localhost:5000/ -d @-
# => You sent: File contents here
```

## Spec References

- HTTP request/response events – `PAGI::Spec::Www`
