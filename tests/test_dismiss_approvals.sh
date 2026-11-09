#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=tests/lib/assertions.sh
source "$repo_root/tests/lib/assertions.sh"

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/dismiss-stale-approvals-review-tests.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

fake_curl="$work_dir/fake-curl"
cat > "$fake_curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%q ' "$@" >> "$CURL_LOG"
printf '\n' >> "$CURL_LOG"

url=
page=1
while (( $# > 0 )); do
  case "$1" in
    --data-urlencode)
      if [[ "$2" == page=* ]]; then
        page=${2#page=}
      fi
      shift 2
      ;;
    http://* | https://*)
      url=$1
      shift
      ;;
    *)
      shift
      ;;
  esac
done

case "$url" in
  */pulls/42)
    printf '{"head":{"sha":"%s"}}\n' "$LIVE_HEAD_SHA"
    ;;
  */pulls/42/reviews)
    if [[ "${REVIEWS_PAGINATED:-false}" == "true" && "$page" == "1" ]]; then
      jq -n '[range(0; 100) | {id: (1000 + .), state: "COMMENTED"}]'
    elif [[ "${REVIEWS_PAGINATED:-false}" == "true" && "$page" == "2" ]]; then
      printf '%s\n' \
        '[{"id":201,"state":"APPROVED","commit_id":"1111111111111111111111111111111111111111"}]'
    else
      printf '%s\n' "$REVIEWS_RESPONSE"
    fi
    ;;
  */pulls/42/reviews/101/dismissals | */pulls/42/reviews/104/dismissals | */pulls/42/reviews/105/dismissals | */pulls/42/reviews/106/dismissals | */pulls/42/reviews/201/dismissals)
    printf '%s\n' '{}'
    ;;
  */issues/42/comments)
    cat >> "$COMMENT_LOG"
    printf '%s\n' '{}'
    ;;
  */pulls/42/requested_reviewers)
    request_body=$(cat)
    printf '%s\n' "$request_body" >> "$REREQUEST_LOG"
    if [[ -n "${FAIL_REREQUEST_FOR:-}" ]] &&
      jq -e --arg login "$FAIL_REREQUEST_FOR" '.reviewers | index($login)' >/dev/null <<< "$request_body"; then
      printf '%s\n' '{"message":"Review cannot be requested"}' >&2
      exit 22
    fi
    printf '%s\n' '{}'
    ;;
  *)
    printf 'Unexpected URL: %s\n' "$url" >&2
    exit 1
    ;;
esac
EOF
chmod 700 "$fake_curl"

export CURL_LOG="$work_dir/curl.log"
export REREQUEST_LOG="$work_dir/rerequest.log"
export COMMENT_LOG="$work_dir/comment.log"
export LIVE_HEAD_SHA='2222222222222222222222222222222222222222'
export REVIEWS_RESPONSE='[
  {"id":101,"state":"APPROVED","commit_id":"1111111111111111111111111111111111111111","user":{"login":"alice"}},
  {"id":102,"state":"APPROVED","commit_id":"2222222222222222222222222222222222222222","user":{"login":"bob"}}
]'

: > "$CURL_LOG"
: > "$REREQUEST_LOG"
: > "$COMMENT_LOG"
GITHUB_TOKEN='test-token' CURL_BIN="$fake_curl" \
  "$repo_root/dismiss_approvals.sh" \
  owner/repository \
  42 \
  false \
  "Security policy" \
  "2222222222222222222222222222222222222222"
assert_file_contains \
  '/pulls/42/reviews/101/dismissals' \
  "$CURL_LOG" \
  "an approval for an older commit should be dismissed"
assert_file_not_contains \
  '/pulls/42/reviews/102/dismissals' \
  "$CURL_LOG" \
  "an approval for the current head must be preserved"
assert_file_not_contains \
  'test-token' \
  "$CURL_LOG" \
  "the token must not be exposed in curl arguments"
assert_equals \
  '{"reviewers":["alice"]}' \
  "$(jq -c . "$REREQUEST_LOG")" \
  "only the reviewer whose approval was dismissed should be re-requested"

# Two stale approvals from one reviewer are both dismissed, but the reviewer
# is re-requested once. Approvals from accounts that cannot review (a bot or a
# deleted user) are dismissed without a re-request.
: > "$CURL_LOG"
: > "$REREQUEST_LOG"
REVIEWS_RESPONSE='[
  {"id":101,"state":"APPROVED","commit_id":"1111111111111111111111111111111111111111","user":{"login":"alice"}},
  {"id":104,"state":"APPROVED","commit_id":"1111111111111111111111111111111111111111","user":{"login":"alice"}},
  {"id":105,"state":"APPROVED","commit_id":"1111111111111111111111111111111111111111","user":{"login":"ci-helper[bot]"}},
  {"id":106,"state":"APPROVED","commit_id":"1111111111111111111111111111111111111111","user":null}
]'
GITHUB_TOKEN='test-token' CURL_BIN="$fake_curl" \
  "$repo_root/dismiss_approvals.sh" \
  owner/repository \
  42 \
  false \
  "Security policy" \
  "2222222222222222222222222222222222222222"
for review_id in 101 104 105 106; do
  assert_file_contains \
    "/pulls/42/reviews/${review_id}/dismissals" \
    "$CURL_LOG" \
    "every stale approval should be dismissed"
done
assert_equals \
  '{"reviewers":["alice"]}' \
  "$(jq -c . "$REREQUEST_LOG")" \
  "a reviewer should be re-requested once and bots or deleted users skipped"

# A failed re-request is only a missed notification: the approval stays
# dismissed and the job still succeeds.
: > "$CURL_LOG"
: > "$REREQUEST_LOG"
REVIEWS_RESPONSE='[
  {"id":101,"state":"APPROVED","commit_id":"1111111111111111111111111111111111111111","user":{"login":"alice"}},
  {"id":104,"state":"APPROVED","commit_id":"1111111111111111111111111111111111111111","user":{"login":"carol"}}
]'
rerequest_output="$work_dir/rerequest-failure-output.txt"
FAIL_REREQUEST_FOR=alice GITHUB_TOKEN='test-token' CURL_BIN="$fake_curl" \
  "$repo_root/dismiss_approvals.sh" \
  owner/repository \
  42 \
  false \
  "Security policy" \
  "2222222222222222222222222222222222222222" > "$rerequest_output" 2>&1
assert_file_contains \
  '/pulls/42/reviews/101/dismissals' \
  "$CURL_LOG" \
  "an approval should be dismissed even if its re-request later fails"
assert_file_contains \
  '/pulls/42/reviews/104/dismissals' \
  "$CURL_LOG" \
  "later approvals should still be dismissed after a failed re-request"
assert_file_contains \
  '"carol"' \
  "$REREQUEST_LOG" \
  "later reviewers should still be re-requested after a failed re-request"
assert_file_contains \
  '::warning::Could not re-request review from alice' \
  "$rerequest_output" \
  "a failed re-request should be reported as a warning"

# A failed dismissal fails the job and must not re-request the reviewer.
: > "$REREQUEST_LOG"
REVIEWS_RESPONSE='[
  {"id":999,"state":"APPROVED","commit_id":"1111111111111111111111111111111111111111","user":{"login":"alice"}}
]'
if GITHUB_TOKEN='test-token' CURL_BIN="$fake_curl" \
  "$repo_root/dismiss_approvals.sh" \
  owner/repository \
  42 \
  false \
  "Security policy" \
  "2222222222222222222222222222222222222222" >/dev/null 2>&1; then
  fail "a failed dismissal should fail the job"
fi
assert_equals \
  '' \
  "$(cat "$REREQUEST_LOG")" \
  "a reviewer must not be re-requested when dismissal failed"

REVIEWS_RESPONSE='[
  {"id":101,"state":"APPROVED","commit_id":"1111111111111111111111111111111111111111","user":{"login":"alice"}},
  {"id":102,"state":"APPROVED","commit_id":"2222222222222222222222222222222222222222","user":{"login":"bob"}}
]'

: > "$CURL_LOG"
: > "$REREQUEST_LOG"
: > "$COMMENT_LOG"
GITHUB_TOKEN='test-token' CURL_BIN="$fake_curl" \
  "$repo_root/dismiss_approvals.sh" \
  owner/repository \
  42 \
  true \
  "Security policy" \
  "2222222222222222222222222222222222222222"
assert_file_contains \
  '/issues/42/comments' \
  "$CURL_LOG" \
  "a dry run should create a pull request comment"
assert_file_not_contains \
  '/dismissals' \
  "$CURL_LOG" \
  "a dry run must not dismiss an approval"
assert_equals \
  '' \
  "$(cat "$REREQUEST_LOG")" \
  "a dry run must not re-request a review"
assert_file_contains \
  'Would have re-requested review from: @alice' \
  "$COMMENT_LOG" \
  "a dry run comment should list the reviewers it would re-request"

: > "$CURL_LOG"
: > "$REREQUEST_LOG"
LIVE_HEAD_SHA='3333333333333333333333333333333333333333'
GITHUB_TOKEN='test-token' CURL_BIN="$fake_curl" \
  "$repo_root/dismiss_approvals.sh" \
  owner/repository \
  42 \
  false \
  "Security policy" \
  "2222222222222222222222222222222222222222"
assert_file_not_contains \
  '/dismissals' \
  "$CURL_LOG" \
  "an outdated workflow must not dismiss approvals on a newer head"
assert_equals \
  '' \
  "$(cat "$REREQUEST_LOG")" \
  "an outdated workflow must not re-request reviews"
LIVE_HEAD_SHA='2222222222222222222222222222222222222222'

REVIEWS_RESPONSE='[{"id":103,"state":"APPROVED","commit_id":null}]'
if GITHUB_TOKEN='test-token' CURL_BIN="$fake_curl" \
  "$repo_root/dismiss_approvals.sh" \
  owner/repository \
  42 \
  false \
  "Security policy" \
  "2222222222222222222222222222222222222222" >/dev/null 2>&1; then
  fail "malformed approved-review data should fail closed"
fi

: > "$CURL_LOG"
REVIEWS_PAGINATED=true
export REVIEWS_PAGINATED
GITHUB_TOKEN='test-token' CURL_BIN="$fake_curl" \
  "$repo_root/dismiss_approvals.sh" \
  owner/repository \
  42 \
  false \
  "Security policy" \
  "2222222222222222222222222222222222222222"
assert_file_contains \
  '/pulls/42/reviews/201/dismissals' \
  "$CURL_LOG" \
  "an approval on the second reviews page should be dismissed"

echo "Approval-dismissal tests passed."
