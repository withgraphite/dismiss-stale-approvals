#!/bin/bash
# Cases for keeping approvals of the passed head SHA while dismissing stale ones.
# The mock GitHub API is started per test. The script must not GET the pull request.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

REASON='See the output of `git range-diff` at https://github.com/acme/app/actions/runs/1'
MOCK_PID=
STATE_FILE=
PORT_FILE=
CONFIG=
SCRIPT_OUTPUT=
PORT=

cleanup() {
  if [ -n "${MOCK_PID:-}" ]; then
    kill "$MOCK_PID" 2>/dev/null || true
    wait "$MOCK_PID" 2>/dev/null || true
    MOCK_PID=
  fi
}
trap cleanup EXIT

die() {
  echo "FAIL: $*" >&2
  if [ -n "${SCRIPT_OUTPUT:-}" ] && [ -f "$SCRIPT_OUTPUT" ]; then
    echo "----- script output -----" >&2
    cat "$SCRIPT_OUTPUT" >&2
  fi
  if [ -n "${STATE_FILE:-}" ] && [ -f "$STATE_FILE" ]; then
    echo "----- mock state -----" >&2
    cat "$STATE_FILE" >&2
  fi
  exit 1
}

write_config() {
  CONFIG=$(mktemp)
  cat >"$CONFIG"
}

start_mock() {
  cleanup
  STATE_FILE=$(mktemp)
  PORT_FILE=$(mktemp)
  local log
  log=$(mktemp)
  python3 - "$CONFIG" "$STATE_FILE" "$PORT_FILE" >"$log" 2>&1 <<'PY' &
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

config_path, state_path, port_path = sys.argv[1:4]
config = json.load(open(config_path))
STATE = {
    "review_pages": config.get("review_pages") or [config.get("reviews", [])],
    "review_page": 0,
    "calls": [],
    "dismissals": [],
    "comments": [],
    "last_auth": None,
}

def flush():
    public = {
        "calls": STATE["calls"],
        "dismissals": STATE["dismissals"],
        "comments": STATE["comments"],
        "last_auth": STATE["last_auth"],
        "review_page": STATE["review_page"],
    }
    tmp = state_path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(public, fh)
    os_replace(tmp, state_path)

def os_replace(src, dst):
    import os
    os.replace(src, dst)

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        return

    def _read_json(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length) if length else b""
        if not raw:
            return {}
        return json.loads(raw.decode())

    def _send(self, code, body, extra=None):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        if extra:
            for key, value in extra.items():
                self.send_header(key, value)
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)

    def _record(self, method, review_id=None):
        path = urlparse(self.path).path.rstrip("/")
        entry = {"method": method, "path": path}
        if review_id is not None:
            entry["review_id"] = review_id
        auth = self.headers.get("Authorization")
        if auth:
            STATE["last_auth"] = auth
        STATE["calls"].append(entry)
        flush()

    def do_GET(self):
        path = urlparse(self.path).path.rstrip("/")
        if path == "/__state":
            self._send(200, {
                "calls": STATE["calls"],
                "dismissals": STATE["dismissals"],
                "comments": STATE["comments"],
            })
            return
        if path.endswith("/reviews"):
            self._record("GET")
            pages = STATE["review_pages"]
            index = STATE["review_page"]
            page = pages[index] if index < len(pages) else []
            STATE["review_page"] = index + 1
            extra = None
            if index + 1 < len(pages):
                host = self.headers.get("Host")
                nxt = f"http://{host}{path}?per_page=100&page={index + 2}"
                extra = {"Link": f'<{nxt}>; rel="next"'}
            flush()
            self._send(200, page, extra)
            return
        self._send(404, {"message": "not found", "path": path})

    def do_PUT(self):
        body = self._read_json()
        path = urlparse(self.path).path.rstrip("/")
        review_id = int(path.split("/")[-2])
        self._record("PUT", review_id)
        STATE["dismissals"].append({
            "review_id": review_id,
            "message": body.get("message"),
        })
        flush()
        self._send(200, {"id": review_id})

    def do_POST(self):
        body = self._read_json()
        path = urlparse(self.path).path.rstrip("/")
        self._record("POST")
        if path.endswith("/comments"):
            STATE["comments"].append(body)
        flush()
        self._send(201, {"id": 1})

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
port = server.server_address[1]
flush()
with open(port_path, "w") as fh:
    fh.write(str(port))
server.serve_forever()
PY
  MOCK_PID=$!
  local i
  for i in $(seq 1 100); do
    if [ -s "$PORT_FILE" ]; then
      PORT=$(cat "$PORT_FILE")
      if curl -sf "http://127.0.0.1:${PORT}/__state" >/dev/null; then
        export GITHUB_API_URL="http://127.0.0.1:${PORT}"
        return 0
      fi
    fi
    if ! kill -0 "$MOCK_PID" 2>/dev/null; then
      echo "mock server exited early" >&2
      cat "$log" >&2 || true
      exit 1
    fi
    sleep 0.05
  done
  echo "mock server did not start" >&2
  cat "$log" >&2 || true
  exit 1
}

run_script() {
  local dry_run=$1
  SCRIPT_OUTPUT=$(mktemp)
  set +e
  ./dismiss_approvals.sh "test-token" "acme/app" 7 "$HEAD_SHA" "$REASON" "$dry_run" >"$SCRIPT_OUTPUT" 2>&1
  SCRIPT_STATUS=$?
  set -e
  if [ "$SCRIPT_STATUS" -ne 0 ]; then
    die "dismiss_approvals.sh exited ${SCRIPT_STATUS}"
  fi
}

assert_calls() {
  local want=$1
  local got
  got=$(jq -cS '[.calls[] | {method, path, review_id: (.review_id // null)}]' "$STATE_FILE")
  want=$(printf '%s' "$want" | jq -cS .)
  if [ "$got" != "$want" ]; then
    echo "calls mismatch" >&2
    echo "got  $got" >&2
    echo "want $want" >&2
    die "API call order"
  fi
}

assert_dismissals() {
  local want=$1
  local got
  got=$(jq -cS '.dismissals' "$STATE_FILE")
  want=$(printf '%s' "$want" | jq -cS .)
  if [ "$got" != "$want" ]; then
    echo "dismissals mismatch" >&2
    echo "got  $got" >&2
    echo "want $want" >&2
    die "dismissals"
  fi
}

assert_no_writes() {
  local puts posts
  puts=$(jq '[.calls[] | select(.method == "PUT")] | length' "$STATE_FILE")
  posts=$(jq '[.calls[] | select(.method == "POST")] | length' "$STATE_FILE")
  if [ "$puts" != "0" ] || [ "$posts" != "0" ]; then
    die "expected no dismissals or comments, puts=${puts} posts=${posts}"
  fi
}

REVIEWS="/repos/acme/app/pulls/7/reviews"

echo "==> keep approval on the passed SHA"
export HEAD_SHA=sha-head
write_config <<'JSON'
{
  "reviews": [
    {"id": 101, "state": "APPROVED", "commit_id": "sha-head"},
    {"id": 102, "state": "COMMENTED", "commit_id": "sha-older"}
  ]
}
JSON
start_mock
run_script false
assert_calls "$(cat <<JSON
[
  {"method": "GET", "path": "${REVIEWS}", "review_id": null}
]
JSON
)"
assert_no_writes
if ! grep -q "Keeping review 101 on head sha-head" "$SCRIPT_OUTPUT"; then
  die "expected to keep review 101"
fi
auth=$(jq -r '.last_auth' "$STATE_FILE")
if [ "$auth" != "Bearer test-token" ]; then
  die "expected the GitHub token on API requests, got ${auth}"
fi

echo "==> dismiss an approval on an older SHA"
export HEAD_SHA=sha-head
write_config <<'JSON'
{
  "reviews": [
    {"id": 201, "state": "APPROVED", "commit_id": "sha-older"},
    {"id": 202, "state": "CHANGES_REQUESTED", "commit_id": "sha-older"},
    {"id": 203, "state": "COMMENTED", "commit_id": "sha-head"}
  ]
}
JSON
start_mock
run_script false
assert_calls "$(cat <<JSON
[
  {"method": "GET", "path": "${REVIEWS}", "review_id": null},
  {"method": "PUT", "path": "${REVIEWS}/201/dismissals", "review_id": 201}
]
JSON
)"
assert_dismissals "$(jq -nc --arg message "$REASON" '[{review_id: 201, message: $message}]')"

echo "==> missing commit_id is dismissed and the review id is logged"
export HEAD_SHA=sha-head
write_config <<'JSON'
{
  "reviews": [
    {"id": 501, "state": "APPROVED", "commit_id": null},
    {"id": 502, "state": "COMMENTED"}
  ]
}
JSON
start_mock
run_script false
assert_calls "$(cat <<JSON
[
  {"method": "GET", "path": "${REVIEWS}", "review_id": null},
  {"method": "PUT", "path": "${REVIEWS}/501/dismissals", "review_id": 501}
]
JSON
)"
if ! grep -qF "Review 501 has no commit_id; dismissing" "$SCRIPT_OUTPUT"; then
  die "expected the missing commit_id warning to include review 501"
fi
if grep -qF "Review 502" "$SCRIPT_OUTPUT"; then
  die "a non-approved review without commit_id should not be logged for dismissal"
fi
warnings=$(grep -c "has no commit_id" "$SCRIPT_OUTPUT")
if [ "$warnings" != "1" ]; then
  die "expected one missing commit_id log line, got ${warnings}"
fi

echo "==> follow review pagination and still apply the head check"
export HEAD_SHA=sha-head
write_config <<'JSON'
{
  "review_pages": [
    [{"id": 801, "state": "APPROVED", "commit_id": "sha-head"}],
    [{"id": 802, "state": "APPROVED", "commit_id": "sha-older"}]
  ]
}
JSON
start_mock
run_script false
assert_calls "$(cat <<JSON
[
  {"method": "GET", "path": "${REVIEWS}", "review_id": null},
  {"method": "GET", "path": "${REVIEWS}", "review_id": null},
  {"method": "PUT", "path": "${REVIEWS}/802/dismissals", "review_id": 802}
]
JSON
)"
assert_dismissals "$(jq -nc --arg message "$REASON" '[{review_id: 802, message: $message}]')"

echo "==> dry run comments for stale approvals and does not dismiss the passed SHA"
export HEAD_SHA=sha-head
write_config <<'JSON'
{
  "reviews": [
    {"id": 901, "state": "APPROVED", "commit_id": "sha-head"},
    {"id": 902, "state": "APPROVED", "commit_id": "sha-older"}
  ]
}
JSON
start_mock
run_script true
assert_calls "$(cat <<JSON
[
  {"method": "GET", "path": "${REVIEWS}", "review_id": null},
  {"method": "POST", "path": "/repos/acme/app/issues/7/comments", "review_id": null}
]
JSON
)"
assert_dismissals '[]'
body=$(jq -r '.comments[0].body' "$STATE_FILE")
expected=$(printf 'dismiss_stale_approvals dry run: Would have dismissed 1 approvals with reason:\n\n%s' "$REASON")
if [ "$body" != "$expected" ]; then
  echo "got comment:" >&2
  printf '%s\n' "$body" >&2
  echo "want comment:" >&2
  printf '%s\n' "$expected" >&2
  die "dry-run comment body"
fi

echo "==> omitted commit_id is dismissed the same way as null"
export HEAD_SHA=sha-head
write_config <<'JSON'
{
  "reviews": [
    {"id": 1001, "state": "APPROVED"}
  ]
}
JSON
start_mock
run_script false
assert_calls "$(cat <<JSON
[
  {"method": "GET", "path": "${REVIEWS}", "review_id": null},
  {"method": "PUT", "path": "${REVIEWS}/1001/dismissals", "review_id": 1001}
]
JSON
)"
assert_dismissals "$(jq -nc --arg message "$REASON" '[{review_id: 1001, message: $message}]')"
if ! grep -qF "Review 1001 has no commit_id; dismissing" "$SCRIPT_OUTPUT"; then
  die "expected the missing commit_id warning to include review 1001"
fi

cleanup
echo "ok"
