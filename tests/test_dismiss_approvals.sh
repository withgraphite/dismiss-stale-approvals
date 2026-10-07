#!/bin/bash
# Cases for keeping approvals of the live head while dismissing stale ones.
# The mock GitHub API is started per test. HEAD_SHA is the frozen payload SHA
# and must not decide which reviews are dismissed.

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
    "pull_shas": config["pull_shas"],
    "pull_index": 0,
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
        "pull_index": STATE["pull_index"],
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
        if "/pulls/" in path:
            self._record("GET")
            shas = STATE["pull_shas"]
            index = STATE["pull_index"]
            if not shas:
                self._send(500, {"message": "no shas"})
                return
            sha = shas[index] if index < len(shas) else shas[-1]
            STATE["pull_index"] = index + 1
            flush()
            self._send(200, {"head": {"sha": sha}})
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
  ./dismiss_approvals.sh "test-token" "acme/app" 7 "$REASON" "$dry_run" >"$SCRIPT_OUTPUT" 2>&1
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

assert_listed_after_live_head() {
  local first second
  first=$(jq -r '.calls[0] | .method + " " + .path' "$STATE_FILE")
  second=$(jq -r '.calls[1] | .method + " " + .path' "$STATE_FILE")
  if [ "$first" != "GET /repos/acme/app/pulls/7" ]; then
    die "expected a pull request fetch before listing reviews, got ${first}"
  fi
  if [ "$second" != "GET /repos/acme/app/pulls/7/reviews" ]; then
    die "expected list reviews immediately after the live head fetch, got ${second}"
  fi
}

PULL="/repos/acme/app/pulls/7"
REVIEWS="/repos/acme/app/pulls/7/reviews"

echo "==> keep approval when the head is still the SHA that started the job"
export HEAD_SHA=sha-job-start
write_config <<'JSON'
{
  "pull_shas": ["sha-job-start", "sha-should-not-be-read"],
  "reviews": [
    {"id": 101, "state": "APPROVED", "commit_id": "sha-job-start"},
    {"id": 102, "state": "COMMENTED", "commit_id": "sha-older"}
  ]
}
JSON
start_mock
run_script false
assert_listed_after_live_head
assert_no_writes
if ! grep -q "Keeping review 101 on current head sha-job-start" "$SCRIPT_OUTPUT"; then
  die "expected to keep review 101"
fi
auth=$(jq -r '.last_auth' "$STATE_FILE")
if [ "$auth" != "Bearer test-token" ]; then
  die "expected the GitHub token on API requests, got ${auth}"
fi

echo "==> dismiss an approval on an older SHA"
export HEAD_SHA=sha-job-start
write_config <<'JSON'
{
  "pull_shas": ["sha-job-start", "sha-job-start"],
  "reviews": [
    {"id": 201, "state": "APPROVED", "commit_id": "sha-older"},
    {"id": 202, "state": "CHANGES_REQUESTED", "commit_id": "sha-older"},
    {"id": 203, "state": "COMMENTED", "commit_id": "sha-job-start"}
  ]
}
JSON
start_mock
run_script false
assert_calls "$(cat <<JSON
[
  {"method": "GET", "path": "${PULL}", "review_id": null},
  {"method": "GET", "path": "${REVIEWS}", "review_id": null},
  {"method": "GET", "path": "${PULL}", "review_id": null},
  {"method": "PUT", "path": "${PULL}/reviews/201/dismissals", "review_id": 201}
]
JSON
)"
assert_dismissals "$(jq -nc --arg message "$REASON" '[{review_id: 201, message: $message}]')"

echo "==> head moved before listReviews: keep an approval of the newest SHA"
export HEAD_SHA=sha-job-start
write_config <<'JSON'
{
  "pull_shas": ["sha-newest", "sha-moved-after-list"],
  "reviews": [
    {"id": 301, "state": "APPROVED", "commit_id": "sha-newest"}
  ]
}
JSON
start_mock
run_script false
assert_listed_after_live_head
assert_no_writes
if ! grep -q "Keeping review 301 on current head sha-newest" "$SCRIPT_OUTPUT"; then
  die "expected to keep the approval of the newest head"
fi
if grep -q "sha-job-start" "$SCRIPT_OUTPUT"; then
  die "payload SHA leaked into the keep decision"
fi

echo "==> head moved before listReviews: dismiss an approval of the SHA that started the run"
export HEAD_SHA=sha-job-start
write_config <<'JSON'
{
  "pull_shas": ["sha-newest", "sha-newest"],
  "reviews": [
    {"id": 401, "state": "APPROVED", "commit_id": "sha-job-start"}
  ]
}
JSON
start_mock
run_script false
assert_calls "$(cat <<JSON
[
  {"method": "GET", "path": "${PULL}", "review_id": null},
  {"method": "GET", "path": "${REVIEWS}", "review_id": null},
  {"method": "GET", "path": "${PULL}", "review_id": null},
  {"method": "PUT", "path": "${PULL}/reviews/401/dismissals", "review_id": 401}
]
JSON
)"
assert_dismissals "$(jq -nc --arg message "$REASON" '[{review_id: 401, message: $message}]')"
if ! grep -q "Dismissing review 401" "$SCRIPT_OUTPUT"; then
  die "expected to dismiss the approval of the payload SHA"
fi

echo "==> missing commit_id is dismissed and the review id is logged"
export HEAD_SHA=sha-job-start
write_config <<'JSON'
{
  "pull_shas": ["sha-job-start", "sha-job-start"],
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
  {"method": "GET", "path": "${PULL}", "review_id": null},
  {"method": "GET", "path": "${REVIEWS}", "review_id": null},
  {"method": "GET", "path": "${PULL}", "review_id": null},
  {"method": "PUT", "path": "${PULL}/reviews/501/dismissals", "review_id": 501}
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

echo "==> head moves after listReviews: keep an approval that matches the head at dismiss time"
export HEAD_SHA=sha-job-start
write_config <<'JSON'
{
  "pull_shas": ["sha-at-list", "sha-at-dismiss"],
  "reviews": [
    {"id": 601, "state": "APPROVED", "commit_id": "sha-at-dismiss"}
  ]
}
JSON
start_mock
run_script false
assert_calls "$(cat <<JSON
[
  {"method": "GET", "path": "${PULL}", "review_id": null},
  {"method": "GET", "path": "${REVIEWS}", "review_id": null},
  {"method": "GET", "path": "${PULL}", "review_id": null}
]
JSON
)"
assert_no_writes
if ! grep -q "matches head sha-at-dismiss at dismiss time" "$SCRIPT_OUTPUT"; then
  die "expected the dismiss-time head check to keep review 601"
fi

echo "==> re-fetch the live head before each dismissal"
export HEAD_SHA=sha-job-start
write_config <<'JSON'
{
  "pull_shas": ["sha-list", "sha-list", "sha-old-2"],
  "reviews": [
    {"id": 701, "state": "APPROVED", "commit_id": "sha-old-1"},
    {"id": 702, "state": "APPROVED", "commit_id": "sha-old-2"}
  ]
}
JSON
start_mock
run_script false
assert_calls "$(cat <<JSON
[
  {"method": "GET", "path": "${PULL}", "review_id": null},
  {"method": "GET", "path": "${REVIEWS}", "review_id": null},
  {"method": "GET", "path": "${PULL}", "review_id": null},
  {"method": "PUT", "path": "${PULL}/reviews/701/dismissals", "review_id": 701},
  {"method": "GET", "path": "${PULL}", "review_id": null}
]
JSON
)"
assert_dismissals "$(jq -nc --arg message "$REASON" '[{review_id: 701, message: $message}]')"
if ! grep -q "matches head sha-old-2 at dismiss time" "$SCRIPT_OUTPUT"; then
  die "expected review 702 to be kept after the per-dismiss head fetch"
fi

echo "==> follow review pagination and still apply the head check"
export HEAD_SHA=sha-job-start
write_config <<'JSON'
{
  "pull_shas": ["sha-job-start", "sha-job-start"],
  "review_pages": [
    [{"id": 801, "state": "APPROVED", "commit_id": "sha-job-start"}],
    [{"id": 802, "state": "APPROVED", "commit_id": "sha-older"}]
  ]
}
JSON
start_mock
run_script false
assert_calls "$(cat <<JSON
[
  {"method": "GET", "path": "${PULL}", "review_id": null},
  {"method": "GET", "path": "${REVIEWS}", "review_id": null},
  {"method": "GET", "path": "${REVIEWS}", "review_id": null},
  {"method": "GET", "path": "${PULL}", "review_id": null},
  {"method": "PUT", "path": "${PULL}/reviews/802/dismissals", "review_id": 802}
]
JSON
)"
assert_dismissals "$(jq -nc --arg message "$REASON" '[{review_id: 802, message: $message}]')"

echo "==> dry run comments for stale approvals and does not dismiss the current head"
export HEAD_SHA=sha-job-start
write_config <<'JSON'
{
  "pull_shas": ["sha-job-start", "sha-job-start"],
  "reviews": [
    {"id": 901, "state": "APPROVED", "commit_id": "sha-job-start"},
    {"id": 902, "state": "APPROVED", "commit_id": "sha-older"}
  ]
}
JSON
start_mock
run_script true
assert_calls "$(cat <<JSON
[
  {"method": "GET", "path": "${PULL}", "review_id": null},
  {"method": "GET", "path": "${REVIEWS}", "review_id": null},
  {"method": "GET", "path": "${PULL}", "review_id": null},
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
export HEAD_SHA=sha-job-start
write_config <<'JSON'
{
  "pull_shas": ["sha-job-start", "sha-job-start"],
  "reviews": [
    {"id": 1001, "state": "APPROVED"}
  ]
}
JSON
start_mock
run_script false
assert_dismissals "$(jq -nc --arg message "$REASON" '[{review_id: 1001, message: $message}]')"
if ! grep -qF "Review 1001 has no commit_id; dismissing" "$SCRIPT_OUTPUT"; then
  die "expected the missing commit_id warning to include review 1001"
fi

cleanup
echo "ok"
