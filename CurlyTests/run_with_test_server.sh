#!/usr/bin/env zsh
set -euo pipefail

server_url="http://localhost:9999/json"
server_pid=""
tls_server_pid=""
tls_temp_dir=""
tls_server_url="https://localhost:9443/json"

server_reachable() {
    /usr/bin/python3 - "$1" "${2:-verify}" <<'PY'
import ssl
import sys
import urllib.request

try:
    context = ssl._create_unverified_context() if sys.argv[2] == "insecure" else None
    with urllib.request.urlopen(sys.argv[1], timeout=0.5, context=context) as response:
        sys.exit(0 if response.status == 200 else 1)
except Exception:
    sys.exit(1)
PY
}

cleanup() {
    if [[ -n "${tls_server_pid}" ]]; then
        kill "${tls_server_pid}" >/dev/null 2>&1 || true
        wait "${tls_server_pid}" >/dev/null 2>&1 || true
    fi
    if [[ -n "${server_pid}" ]]; then
        kill "${server_pid}" >/dev/null 2>&1 || true
        wait "${server_pid}" >/dev/null 2>&1 || true
    fi
    if [[ -n "${tls_temp_dir}" ]]; then
        rm -rf "${tls_temp_dir}"
    fi
}
trap cleanup EXIT INT TERM

if ! server_reachable "$server_url"; then
    /usr/bin/python3 CurlyTests/test_server.py >/tmp/native-curl-runner-test-server.log 2>&1 &
    server_pid="$!"

    for _ in {1..50}; do
        if server_reachable "$server_url"; then
            break
        fi
        sleep 0.1
    done

    if ! server_reachable "$server_url"; then
        echo "Test server did not become reachable on ${server_url}." >&2
        cat /tmp/native-curl-runner-test-server.log >&2 || true
        exit 1
    fi
fi

tls_temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/curly-tls.XXXXXX")"
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "${tls_temp_dir}/private-key.pem" \
    -out "${tls_temp_dir}/certificate.pem" \
    -days 1 \
    -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost" \
    >"${tls_temp_dir}/openssl.log" 2>&1

/usr/bin/python3 CurlyTests/test_server.py \
    --port 9443 \
    --tls-cert "${tls_temp_dir}/certificate.pem" \
    --tls-key "${tls_temp_dir}/private-key.pem" \
    >"${tls_temp_dir}/server.log" 2>&1 &
tls_server_pid="$!"

for _ in {1..50}; do
    if server_reachable "$tls_server_url" insecure; then
        break
    fi
    sleep 0.1
done

if ! server_reachable "$tls_server_url" insecure; then
    echo "TLS test server did not become reachable on ${tls_server_url}." >&2
    cat "${tls_temp_dir}/server.log" >&2 || true
    exit 1
fi

"$@"
