# 08 – TLS Extension Introspection

Reads `scope->{extensions}{tls}` when present and reports certificate/version/cipher data back to the client. Falls back gracefully for non-TLS requests.

## Quick Start

**1. Start the server with TLS:**

```bash
# Generate self-signed cert for testing (if needed)
openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 365 -nodes -subj "/CN=localhost"

# Start with TLS enabled
pagi-server --app examples/08-tls-introspection/app.pl --port 5000 \
  --tls-cert cert.pem --tls-key key.pem
```

**2. Demo with curl:**

```bash
# HTTPS request - shows TLS info
curl -k https://localhost:5000/
# => TLS Connection Info:
# => Protocol: TLSv1.3
# => Cipher: TLS_AES_256_GCM_SHA384
# => ...

# HTTP request (without TLS) - shows fallback message
curl http://localhost:5000/
# => No TLS connection detected
```

**Note:** Use `-k` flag with curl to accept self-signed certificates.

## Spec References

- TLS extension – `PAGI::Spec::Tls`
- HTTP response events – `PAGI::Spec::Www`
