# Test Server

A lightweight HTTP test server for developing and testing Curly.
Built with Python stdlib — zero dependencies.

## Quick Start

```bash
just test-server
```

Or directly:

```bash
python3 CurlyTests/test_server.py
```

Server starts on **http://localhost:9999**. Press `Ctrl+C` to stop.

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/` | HTML index with links and curl examples |
| `GET` | `/json` | Simple JSON `{"key": "value"}` |
| `GET` | `/json/complex` | ~200-line nested JSON (objects, arrays, edge cases) |
| `GET` | `/html` | Minimal HTML page |
| `GET` | `/text` | Plain text response |
| `GET` | `/get` | Echo request: method, headers, query args |
| `POST` | `/post` | Echo request + body (JSON/form-data) |
| `PUT` | `/put` | Same |
| `PATCH` | `/patch` | Same |
| `DELETE` | `/delete` | Same |
| `POST` | `/form` | Parse and echo `application/x-www-form-urlencoded` |
| `POST` | `/upload` | Echo file upload metadata |
| `GET` | `/status/418` | Return any HTTP status code |
| `GET` | `/redirect/3` | N chained 302 redirects (final → `/get`) |
| `GET` | `/redirect-to?url=/get` | Redirect to an arbitrary URL |
| `GET` | `/delay/2.5` | Wait N seconds before responding |
| `ANY` | `/headers` | Echo all request headers as JSON |
| `ANY` | `/anything` | Universal echo (method, path, headers, body, args) |
| `ANY` | `/anything/foo/bar` | Same with sub-path |
| `GET` | `/basic-auth/user/pass` | HTTP Basic Auth — match credentials or 401 |
| `GET` | `/bearer` | Bearer token auth — any token = 200, none = 401 |
| `GET` | `/api-key?key=secret123` | API key via query param (must start with `secret`) |
| `GET` | `/cookies` | Echo request cookies |
| `GET` | `/cookies/set?name=value` | Set cookies via `Set-Cookie` header |
| `GET` | `/response-headers?X-Custom=hello` | Return custom response headers |
| `GET` | `/stream/20` | Newline-delimited JSON |
| `OPTIONS` | `/*` | CORS preflight response |

## Examples

These are the exact curl patterns the GUI wrapper is designed to import and run:

```bash
# GET with query params
curl "http://localhost:9999/get?name=alice&age=30&active=true"

# POST with JSON body (Content-Type: application/json)
curl -X POST http://localhost:9999/post \
  -H "Content-Type: application/json" \
  -d '{"title": "hello", "count": 42}'

# POST with form-urlencoded (-d implies POST)
curl -d "username=jane&password=secret123" http://localhost:9999/form

# PUT with raw body
curl -X PUT http://localhost:9999/put \
  -H "Content-Type: text/plain" \
  -d "some raw text body"

# DELETE
curl -X DELETE http://localhost:9999/delete

# PATCH with partial JSON
curl -X PATCH http://localhost:9999/patch \
  -H "Content-Type: application/json" \
  -d '{"status": "updated"}'

# Custom headers
curl -H "Authorization: Bearer my-token" \
  -H "X-Custom-Header: value" \
  http://localhost:9999/headers

# Basic auth (-u flag)
curl -u admin:secret http://localhost:9999/basic-auth/admin/secret

# Bearer token auth
curl -H "Authorization: Bearer my-secret-token" http://localhost:9999/bearer

# API key via query param
curl "http://localhost:9999/api-key?key=secret123"

# Follow redirects
curl -L http://localhost:9999/redirect/3

# File upload (-F)
curl -F "file=@test_server.py" http://localhost:9999/upload

# Save and send cookies
curl -c /tmp/cookies.txt http://localhost:9999/cookies/set?session=abc
curl -b /tmp/cookies.txt http://localhost:9999/cookies

# Custom status code (e.g. 418 I'm a Teapot)
curl -w "\nHTTP %{http_code}\n" http://localhost:9999/status/418

# Timeout testing
curl --max-time 1 http://localhost:9999/delay/5

# Response headers with -i
curl -i http://localhost:9999/response-headers?X-Custom=hello

# Stream (newline-delimited JSON)
curl http://localhost:9999/stream/5

# Complex JSON (pipe into json.tool for pretty-print)
curl http://localhost:9999/json/complex | python3 -m json.tool

# Universal echo — any method, any path
curl -X OPTIONS http://localhost:9999/anything
curl -X PROPFIND http://localhost:9999/anything/custom/path
```

## Usage from Swift Tests

```swift
let server = Process()
server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
server.arguments = ["CurlyTests/test_server.py"]
try server.run()
defer { server.terminate() }

// Use http://localhost:9999 in your tests
```

## Response Headers

Every response includes:

- `Content-Type` — appropriate to the endpoint
- `Access-Control-Allow-Origin: *`
- `X-Request-Method` — the HTTP method used
- `X-Request-Path` — the request path
- `Content-Length` — response body size

## Extending

Add a handler function and register it in the `routes` list:

```python
def handle_ping(h, m, p, q, groups):
    respond(h, 200, {"pong": True})

routes.insert(0, (("GET", r"/ping$"), handle_ping))
```

Routes are matched by `(method_pattern, regex_pattern)`. Use `"ANY"` to match all
methods. Regex capture groups are passed to the handler via `groups`.
