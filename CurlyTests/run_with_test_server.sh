#!/usr/bin/env zsh
set -euo pipefail

server_url="http://localhost:9999/json"
server_pid=""

server_reachable() {
    /usr/bin/python3 - "$server_url" <<'PY'
import sys
import urllib.request

try:
    with urllib.request.urlopen(sys.argv[1], timeout=0.5) as response:
        sys.exit(0 if response.status == 200 else 1)
except Exception:
    sys.exit(1)
PY
}

if ! server_reachable; then
    /usr/bin/python3 CurlyTests/test_server.py >/tmp/native-curl-runner-test-server.log 2>&1 &
    server_pid="$!"

    cleanup() {
        if [[ -n "${server_pid}" ]]; then
            kill "${server_pid}" >/dev/null 2>&1 || true
            wait "${server_pid}" >/dev/null 2>&1 || true
        fi
    }
    trap cleanup EXIT INT TERM

    for _ in {1..50}; do
        if server_reachable; then
            break
        fi
        sleep 0.1
    done

    if ! server_reachable; then
        echo "Test server did not become reachable on ${server_url}." >&2
        cat /tmp/native-curl-runner-test-server.log >&2 || true
        exit 1
    fi
fi

"$@"
