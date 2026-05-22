#!/usr/bin/env python3
"""Lightweight HTTP test server for Curly development and testing.

Serves on http://localhost:9999.
Supports common HTTP methods, content types, auth schemes, redirects,
delays, streaming, and a complex JSON endpoint for parser testing.
"""

from http.server import HTTPServer, BaseHTTPRequestHandler
import json
import urllib.parse
import base64
import time
import os
import re

PORT = 9999

# ── Helpers ─────────────────────────────────────────────────────────────────

def respond(h, status, data, content_type="application/json; charset=utf-8"):
    if isinstance(data, (dict, list)):
        body = json.dumps(data, indent=2, ensure_ascii=False).encode("utf-8")
    elif isinstance(data, str):
        body = data.encode("utf-8")
    else:
        body = data
    h.send_response(status)
    h.send_header("Content-Type", content_type)
    h.send_header("Content-Length", str(len(body)))
    h.send_header("Access-Control-Allow-Origin", "*")
    h.send_header("X-Request-Method", h.command)
    h.send_header("X-Request-Path", urllib.parse.urlparse(h.path).path)
    h.end_headers()
    h.wfile.write(body)


def read_body(h):
    length = int(h.headers.get("Content-Length", 0))
    if length > 0:
        return h.rfile.read(length).decode("utf-8")
    return ""


def read_body_bytes(h):
    length = int(h.headers.get("Content-Length", 0))
    if length > 0:
        return h.rfile.read(length)
    return b""


def simplify_qs(qs):
    return {k: v[0] if len(v) == 1 else v for k, v in qs.items()}


# ── Complex JSON payload (~100 lines when pretty-printed) ───────────────────

COMPLEX_JSON = {
    "title": "Complex JSON Test Payload",
    "description": "A comprehensive JSON document for testing JSON parsers and formatters. Contains deeply nested objects, various array types, all JSON data types, unicode, and edge cases.",
    "version": "2.0.1",
    "metadata": {
        "generated_at": "2026-05-21T12:00:00Z",
        "author": "Curly Test Server",
        "tags": ["test", "json", "parsing", "validation", "edge-cases"],
        "counts": {
            "total_keys": 47,
            "nested_objects": 6,
            "arrays": 5,
            "strings": 18,
            "numbers": 12,
            "booleans": 4,
            "nulls": 2
        }
    },
    "scalars": {
        "string": "hello world",
        "empty_string": "",
        "integer": 42,
        "negative": -273,
        "float": 3.141592653589793,
        "scientific_positive": 6.022e23,
        "scientific_negative": 1.602e-19,
        "zero": 0,
        "large_number": 9007199254740993,
        "boolean_true": True,
        "boolean_false": False,
        "null_value": None,
        "unicode": "日本語 Español العربية 😊🔥🚀",
        "special_chars": "tab\there and newline\nhere and \"quotes\" and \\backslash\\",
        "emoji_only": "🎉💯🔥🚀⭐"
    },
    "nested_object": {
        "level1": {
            "level2": {
                "level3": {
                    "level4": {
                        "value": "deeply nested at depth 5",
                        "number": 42
                    }
                }
            }
        }
    },
    "array_of_objects": [
        {
            "id": 1,
            "name": "Alice",
            "role": "admin",
            "active": True,
            "scores": [98, 95, 100]
        },
        {
            "id": 2,
            "name": "Bob",
            "role": "user",
            "active": False,
            "scores": [75, 82, 79]
        },
        {
            "id": 3,
            "name": "Charlie",
            "role": "moderator",
            "active": True,
            "scores": [88, 91, 85]
        },
        {
            "id": 4,
            "name": "Diana",
            "role": "user",
            "active": True,
            "metadata": {
                "last_login": "2026-05-20",
                "login_count": 142
            }
        }
    ],
    "array_of_arrays": [
        [1, 2, 3],
        [4, 5, 6],
        [7, 8, 9],
        [10, 11, 12]
    ],
    "mixed_array": [
        42,
        "a string",
        True,
        False,
        None,
        {"nested_key": "nested_value", "another": 99},
        [1, [2, [3, [4]]]],
        3.14,
        -1,
        ""
    ],
    "flat_arrays": {
        "numbers": [1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
        "strings": ["apple", "banana", "cherry", "date", "elderberry"],
        "booleans": [True, False, True, True, False],
        "mixed": [1, "two", 3.0, False, None],
        "empty": []
    },
    "edge_cases": {
        "empty_object": {},
        "zero_length_string": "",
        "very_small_float": 1e-300,
        "very_large_float": 1e300,
        "negative_zero": -0.0,
        "control_char_string": "tab\there and newline\nhere",
        "escaped_quotes_string": "she said \"hello world\" and left",
        "backslash_string": "C:\\Users\\test\\path\\to\\nowhere",
        "multiple_nulls": [
            None,
            None,
            {"nested_null": None},
            [None, {"deep_null": None}]
        ]
    }
}

# ── Index HTML ──────────────────────────────────────────────────────────────

INDEX_HTML = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Curly Test Server</title>
<style>
  body {{ font-family: -apple-system, BlinkMacSystemFont, sans-serif; max-width: 900px; margin: 2em auto; padding: 0 1em; line-height: 1.6; }}
  h1 {{ border-bottom: 2px solid #eee; padding-bottom: 0.3em; }}
  table {{ border-collapse: collapse; width: 100%; margin: 1em 0; }}
  th, td {{ text-align: left; padding: 6px 12px; border-bottom: 1px solid #ddd; }}
  th {{ background: #f5f5f5; font-weight: 600; }}
  code {{ background: #f0f0f0; padding: 1px 5px; border-radius: 3px; font-size: 0.9em; }}
  tr:hover td {{ background: #fafafa; }}
  .method {{ font-weight: 600; font-family: monospace; }}
  .get {{ color: #2e7d32; }}
  .post {{ color: #1565c0; }}
  .put {{ color: #e65100; }}
  .patch {{ color: #6a1b9a; }}
  .delete {{ color: #c62828; }}
  .any {{ color: #555; }}
  .opt {{ color: #00838f; }}
</style>
</head>
<body>
<h1>Curly Test Server</h1>
<p>Listening on <strong>http://localhost:{PORT}</strong></p>

<table>
<thead><tr><th>Method</th><th>Path</th><th>Description</th></tr></thead>
<tbody>
<tr><td class="method get">GET</td><td><code>/</code></td><td>This page</td></tr>
<tr><td class="method get">GET</td><td><code>/json</code></td><td>Simple JSON response</td></tr>
<tr><td class="method get">GET</td><td><code>/json/complex</code></td><td>Complex nested JSON (~100 lines) for parser testing</td></tr>
<tr><td class="method get">GET</td><td><code>/html</code></td><td>HTML page</td></tr>
<tr><td class="method get">GET</td><td><code>/text</code></td><td>Plain text response</td></tr>
<tr><td class="method get">GET</td><td><code>/get</code></td><td>Echo request details (method, headers, args)</td></tr>
<tr><td class="method post">POST</td><td><code>/post</code></td><td>Echo request details + body</td></tr>
<tr><td class="method put">PUT</td><td><code>/put</code></td><td>Echo request details + body</td></tr>
<tr><td class="method patch">PATCH</td><td><code>/patch</code></td><td>Echo request details + body</td></tr>
<tr><td class="method delete">DELETE</td><td><code>/delete</code></td><td>Echo request details + body</td></tr>
<tr><td class="method post">POST</td><td><code>/form</code></td><td>Parse and echo form-urlencoded data</td></tr>
<tr><td class="method post">POST</td><td><code>/upload</code></td><td>Echo file upload metadata</td></tr>
<tr><td class="method get">GET</td><td><code>/status/418</code></td><td>Return any HTTP status code</td></tr>
<tr><td class="method get">GET</td><td><code>/redirect/3</code></td><td>N chained 302 redirects</td></tr>
<tr><td class="method get">GET</td><td><code>/redirect-to?url=/get</code></td><td>302 redirect to arbitrary URL</td></tr>
<tr><td class="method get">GET</td><td><code>/delay/2.5</code></td><td>Wait N seconds before responding</td></tr>
<tr><td class="method any">ANY</td><td><code>/headers</code></td><td>Echo all request headers as JSON</td></tr>
<tr><td class="method any">ANY</td><td><code>/anything</code></td><td>Universal echo (method, path, headers, body, args)</td></tr>
<tr><td class="method any">ANY</td><td><code>/anything/foo/bar</code></td><td>Universal echo with sub-path</td></tr>
<tr><td class="method get">GET</td><td><code>/basic-auth/user/pass</code></td><td>HTTP Basic Auth (match credentials or 401)</td></tr>
<tr><td class="method get">GET</td><td><code>/bearer</code></td><td>Bearer token auth (any token = 200, none = 401)</td></tr>
<tr><td class="method get">GET</td><td><code>/api-key?key=secret123</code></td><td>API key via query param (must start with <code>secret</code>)</td></tr>
<tr><td class="method get">GET</td><td><code>/cookies</code></td><td>Echo request cookies</td></tr>
<tr><td class="method get">GET</td><td><code>/cookies/set?name=value</code></td><td>Set cookies via <code>Set-Cookie</code> header</td></tr>
<tr><td class="method get">GET</td><td><code>/response-headers?X-Custom=hello</code></td><td>Return custom response headers</td></tr>
<tr><td class="method get">GET</td><td><code>/slow-json</code></td><td>Delayed JSON response (2s sleep) for loading state testing</td></tr>
<tr><td class="method get">GET</td><td><code>/stream/20</code></td><td>Newline-delimited JSON stream</td></tr>
<tr><td class="method opt">OPTIONS</td><td><code>/*</code></td><td>CORS preflight response</td></tr>
</tbody>
</table>

<h2>Examples</h2>
<pre>
# Basic GET
curl http://localhost:{PORT}/json

# POST with JSON body
curl -X POST http://localhost:{PORT}/post \\
  -H "Content-Type: application/json" \\
  -d '{{"hello": "world"}}'

# POST form data
curl -d "name=john&age=30" http://localhost:{PORT}/form

# Basic auth
curl -u admin:secret http://localhost:{PORT}/basic-auth/admin/secret

# Bearer token
curl -H "Authorization: Bearer mytoken123" http://localhost:{PORT}/bearer

# API key
curl http://localhost:{PORT}/api-key?key=secret123

# Follow redirects
curl -L http://localhost:{PORT}/redirect/3

# Custom status
curl http://localhost:{PORT}/status/418

# Timeout testing
curl --max-time 3 http://localhost:{PORT}/delay/2

# Delayed JSON (loading state testing)
curl http://localhost:{PORT}/slow-json

# Stream
curl http://localhost:{PORT}/stream/5

# Complex JSON (for parser testing)
curl http://localhost:{PORT}/json/complex | python3 -m json.tool

# Upload file
curl -F "file=@test.txt" http://localhost:{PORT}/upload

# Set cookies
curl -c /tmp/cookies.txt http://localhost:{PORT}/cookies/set?session=abc123

# Send cookies
curl -b "session=abc123" http://localhost:{PORT}/cookies

# Response headers
curl -D - http://localhost:{PORT}/response-headers?X-Custom=value

# Anything (universal echo)
curl -X PATCH http://localhost:{PORT}/anything \\
  -H "X-Custom: test" \\
  -d "raw body"
</pre>
</body>
</html>"""


# ── Route Handlers ──────────────────────────────────────────────────────────

def handle_index(h, m, p, q, groups):
    respond(h, 200, INDEX_HTML, "text/html; charset=utf-8")


def handle_json(h, m, p, q, groups):
    respond(h, 200, {"key": "value", "method": m, "path": p})


def handle_json_complex(h, m, p, q, groups):
    respond(h, 200, COMPLEX_JSON)


def handle_html(h, m, p, q, groups):
    html = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>HTML Test</title></head><body><h1>HTML Test Page</h1><p>This is a minimal HTML response for testing.</p></body></html>"
    respond(h, 200, html, "text/html; charset=utf-8")


def handle_text(h, m, p, q, groups):
    respond(h, 200, "Hello, this is plain text.\nUseful for testing raw text responses.\n", "text/plain; charset=utf-8")


def handle_echo(h, m, p, q, groups):
    body = read_body(h)
    ct = h.headers.get("Content-Type", "")
    result = {
        "method": m,
        "path": p,
        "headers": dict(h.headers),
        "args": simplify_qs(q)
    }
    if body:
        result["data"] = body
        result["data_size"] = len(body)
        if "application/json" in ct:
            try:
                result["json"] = json.loads(body)
            except Exception:
                result["json_error"] = "Invalid JSON"
        if "application/x-www-form-urlencoded" in ct:
            parsed = urllib.parse.parse_qs(body)
            result["form"] = simplify_qs(parsed)
    respond(h, 200, result)


def handle_form(h, m, p, q, groups):
    body = read_body(h)
    ct = h.headers.get("Content-Type", "")
    parsed = {}
    if "application/x-www-form-urlencoded" in ct:
        parsed = simplify_qs(urllib.parse.parse_qs(body))
    respond(h, 200, {
        "method": m,
        "path": p,
        "content_type": ct,
        "form": parsed,
        "headers": dict(h.headers)
    })


def handle_upload(h, m, p, q, groups):
    body = read_body_bytes(h)
    cd = h.headers.get("Content-Disposition", "")
    filename = None
    for part in cd.split(";"):
        part = part.strip()
        if part.startswith("filename="):
            filename = part[9:].strip('"\'')
    respond(h, 200, {
        "method": m,
        "path": p,
        "content_type": h.headers.get("Content-Type", ""),
        "content_length": len(body),
        "filename": filename,
        "headers": dict(h.headers),
        "body_preview": body[:200].decode("utf-8", errors="replace")
    })


def handle_status(h, m, p, q, groups):
    code = int(groups[0])
    respond(h, code, {"code": code, "method": m, "path": p})


def handle_redirect(h, m, p, q, groups):
    n = int(groups[0])
    target = "/get" if n <= 0 else f"/redirect/{n - 1}"
    h.send_response(302)
    h.send_header("Location", target)
    h.send_header("Access-Control-Allow-Origin", "*")
    h.end_headers()


def handle_redirect_to(h, m, p, q, groups):
    target = q.get("url", [None])[0] or "/get"
    h.send_response(302)
    h.send_header("Location", target)
    h.send_header("Access-Control-Allow-Origin", "*")
    h.end_headers()


def handle_delay(h, m, p, q, groups):
    n = float(groups[0])
    time.sleep(n)
    respond(h, 200, {"delayed": n, "method": m, "path": p})


def handle_headers(h, m, p, q, groups):
    respond(h, 200, {
        "method": m,
        "path": p,
        "headers": dict(h.headers)
    })


def handle_anything(h, m, p, q, groups):
    body_bytes = read_body_bytes(h)
    body = body_bytes.decode("utf-8", errors="replace") if body_bytes else ""
    ct = h.headers.get("Content-Type", "")
    result = {
        "method": m,
        "path": p,
        "headers": dict(h.headers),
        "args": simplify_qs(q),
        "body": body if body else None,
        "body_size": len(body_bytes),
        "url": h.path
    }
    if "application/json" in ct and body:
        try:
            result["json"] = json.loads(body)
        except Exception:
            result["json_error"] = "Invalid JSON"
    if "application/x-www-form-urlencoded" in ct and body:
        result["form"] = simplify_qs(urllib.parse.parse_qs(body))
    respond(h, 200, result)


def handle_basic_auth(h, m, p, q, groups):
    expected_user, expected_pass = groups[0], groups[1]
    auth = h.headers.get("Authorization", "")
    if not auth.startswith("Basic "):
        h.send_response(401)
        h.send_header("WWW-Authenticate", 'Basic realm="Test Server"')
        h.send_header("Content-Type", "application/json; charset=utf-8")
        h.send_header("Access-Control-Allow-Origin", "*")
        h.end_headers()
        h.wfile.write(b'{"error": "Unauthorized"}\n')
        return
    try:
        decoded = base64.b64decode(auth[6:]).decode("utf-8")
        user, password = decoded.split(":", 1)
    except Exception:
        respond(h, 401, {"error": "Invalid Authorization header"})
        return
    if user == expected_user and password == expected_pass:
        respond(h, 200, {"authenticated": True, "user": user})
    else:
        respond(h, 401, {"error": "Invalid credentials"})


def handle_bearer(h, m, p, q, groups):
    auth = h.headers.get("Authorization", "")
    token = auth[7:] if auth.startswith("Bearer ") else None
    if token:
        respond(h, 200, {"authenticated": True, "token": token})
    else:
        respond(h, 401, {"error": "Missing or invalid Bearer token"})


def handle_api_key(h, m, p, q, groups):
    key = q.get("key", [None])[0]
    if key and key.startswith("secret"):
        respond(h, 200, {"authenticated": True, "key": key})
    else:
        respond(h, 401, {
            "error": "Invalid or missing API key",
            "expected": "key query param starting with 'secret'",
            "provided": key
        })


def handle_cookies(h, m, p, q, groups):
    cookie_header = h.headers.get("Cookie", "")
    cookies = {}
    for item in cookie_header.split(";"):
        item = item.strip()
        if "=" in item:
            k, v = item.split("=", 1)
            cookies[k.strip()] = v.strip()
    respond(h, 200, {"cookies": cookies, "method": m, "path": p})


def handle_set_cookies(h, m, p, q, groups):
    h.send_response(200)
    h.send_header("Content-Type", "application/json; charset=utf-8")
    h.send_header("Access-Control-Allow-Origin", "*")
    for k, vals in q.items():
        if vals:
            v = urllib.parse.quote(vals[0])
            h.send_header("Set-Cookie", f"{k}={v}; Path=/; HttpOnly")
    h.end_headers()
    body = json.dumps({"cookies_set": {k: v[0] for k, v in q.items() if v}}, indent=2)
    h.wfile.write((body + "\n").encode("utf-8"))


def handle_response_headers(h, m, p, q, groups):
    h.send_response(200)
    h.send_header("Content-Type", "application/json; charset=utf-8")
    h.send_header("Access-Control-Allow-Origin", "*")
    custom = {}
    for k, vals in q.items():
        if vals and k.startswith("X-"):
            h.send_header(k, vals[0])
            custom[k] = vals[0]
    h.end_headers()
    body = json.dumps({"custom_headers": custom, "method": m, "path": p}, indent=2)
    h.wfile.write((body + "\n").encode("utf-8"))


def handle_slow_json(h, m, p, q, groups):
    time.sleep(2.0)
    respond(h, 200, COMPLEX_JSON)


def handle_stream(h, m, p, q, groups):
    n = int(groups[0])
    lines = [json.dumps({"id": i, "data": f"line {i + 1}"}) + "\n" for i in range(n)]
    body = "".join(lines)
    h.send_response(200)
    h.send_header("Content-Type", "application/x-ndjson; charset=utf-8")
    h.send_header("Content-Length", str(len(body.encode("utf-8"))))
    h.send_header("Access-Control-Allow-Origin", "*")
    h.end_headers()
    h.wfile.write(body.encode("utf-8"))


def handle_options(h, m, p, q, groups):
    h.send_response(204)
    h.send_header("Access-Control-Allow-Origin", "*")
    h.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS, HEAD")
    h.send_header("Access-Control-Allow-Headers", "*")
    h.send_header("Access-Control-Max-Age", "86400")
    h.end_headers()


# ── Route Table ─────────────────────────────────────────────────────────────

routes = [
    (("GET", r"/$"), handle_index),
    (("GET", r"/json$"), handle_json),
    (("GET", r"/json/complex$"), handle_json_complex),
    (("GET", r"/html$"), handle_html),
    (("GET", r"/text$"), handle_text),
    (("GET", r"/get$"), handle_echo),
    (("POST", r"/post$"), handle_echo),
    (("PUT", r"/put$"), handle_echo),
    (("PATCH", r"/patch$"), handle_echo),
    (("DELETE", r"/delete$"), handle_echo),
    (("POST", r"/form$"), handle_form),
    (("POST", r"/upload$"), handle_upload),
    (("GET", r"/status/(\d+)$"), handle_status),
    (("GET", r"/redirect/(\d+)$"), handle_redirect),
    (("GET", r"/redirect-to$"), handle_redirect_to),
    (("GET", r"/delay/([\d.]+)$"), handle_delay),
    (("ANY", r"/headers$"), handle_headers),
    (("ANY", r"/anything$"), handle_anything),
    (("ANY", r"/anything/.+"), handle_anything),
    (("GET", r"/basic-auth/([^/]+)/([^/]+)$"), handle_basic_auth),
    (("GET", r"/bearer$"), handle_bearer),
    (("GET", r"/api-key$"), handle_api_key),
    (("GET", r"/cookies/set$"), handle_set_cookies),
    (("GET", r"/cookies$"), handle_cookies),
    (("GET", r"/response-headers$"), handle_response_headers),
    (("GET", r"/slow-json$"), handle_slow_json),
    (("GET", r"/stream/(\d+)$"), handle_stream),
    (("OPTIONS", r"/.*"), handle_options),
]

# ── Request Handler Class ───────────────────────────────────────────────────

class TestHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        self._handle("GET")

    def do_POST(self):
        self._handle("POST")

    def do_PUT(self):
        self._handle("PUT")

    def do_PATCH(self):
        self._handle("PATCH")

    def do_DELETE(self):
        self._handle("DELETE")

    def do_OPTIONS(self):
        self._handle("OPTIONS")

    def _handle(self, method):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)

        for (m_pattern, p_pattern), handler in routes:
            if m_pattern not in (method, "ANY"):
                continue
            m = re.match(p_pattern, path)
            if m:
                handler(self, method, path, query, m.groups())
                return

        respond(self, 404, {"error": "Not Found", "path": path, "method": method})

    def log_message(self, format, *args):
        pass


# ── Entry Point ─────────────────────────────────────────────────────────────

if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", PORT), TestHandler)
    print(f"  http://localhost:{PORT}")
    print("  Press Ctrl+C to stop.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print()
        server.shutdown()
