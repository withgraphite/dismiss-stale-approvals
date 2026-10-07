#!/bin/bash
# Dismiss APPROVED reviews that are not on the pull request's live head.
#
# Fetch the head SHA from the pull request API immediately before listing
# reviews, and again immediately before each dismissal. HEAD_SHA from the
# workflow payload is frozen when the run starts, so it must not be used here.
# An approval of that payload SHA is stale if a later push has moved the head.

set -euo pipefail

github_token=${1:?github token is required}
repository=${2:?repository is required}
pr_number=${3:?pull request number is required}
reason=${4:?dismissal reason is required}
dry_run=${5:-false}

echoerr() { echo "$@" 1>&2; }

api_base=${GITHUB_API_URL:-https://api.github.com}
api_base=${api_base%/}

case "$dry_run" in
  true|True|TRUE) is_dry_run=1 ;;
  false|False|FALSE|"") is_dry_run=0 ;;
  *)
    echoerr "dry-run must be true or false (got: ${dry_run})"
    exit 1
    ;;
esac

auth_args=(
  -H "Authorization: Bearer ${github_token}"
  -H "Accept: application/vnd.github+json"
)

fetch_head_sha() {
  curl -sS -f "${auth_args[@]}" \
    "${api_base}/repos/${repository}/pulls/${pr_number}" \
    | jq -er '.head.sha'
}

extract_next_url() {
  local headers_file=$1
  local line
  line=$(grep -i '^link:' "$headers_file" | tr -d '\r' || true)
  if [ -z "$line" ]; then
    return 0
  fi
  printf '%s\n' "$line" \
    | tr ',' '\n' \
    | sed -n 's/.*<\([^>]*\)>[[:space:]]*;[[:space:]]*rel="next".*/\1/p' \
    | head -n 1
}

list_reviews() {
  local url="${api_base}/repos/${repository}/pulls/${pr_number}/reviews?per_page=100"
  local combined='[]'
  local headers page_json next
  while [ -n "$url" ]; do
    headers=$(mktemp)
    page_json=$(curl -sS -f -D "$headers" "${auth_args[@]}" "$url")
    combined=$(jq -s '.[0] + .[1]' <(printf '%s\n' "$combined") <(printf '%s\n' "$page_json"))
    next=$(extract_next_url "$headers" || true)
    rm -f "$headers"
    if [ -n "$next" ] && [ "$next" = "$url" ]; then
      break
    fi
    url=$next
  done
  printf '%s\n' "$combined"
}

dismiss_review() {
  local review_id=$1
  local payload
  payload=$(jq -n --arg message "$reason" '{message: $message}')
  curl -sS -f -X PUT "${auth_args[@]}" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "${api_base}/repos/${repository}/pulls/${pr_number}/reviews/${review_id}/dismissals" \
    >/dev/null
}

post_dry_run_comment() {
  local count=$1
  local body payload
  body=$(printf 'dismiss_stale_approvals dry run: Would have dismissed %s approvals with reason:\n\n%s' "$count" "$reason")
  payload=$(jq -n --arg body "$body" '{body: $body}')
  curl -sS -f -X POST "${auth_args[@]}" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "${api_base}/repos/${repository}/issues/${pr_number}/comments" \
    >/dev/null
}

head_sha=$(fetch_head_sha)
if [ -z "$head_sha" ] || [ "$head_sha" = "null" ]; then
  echoerr "Failed to read the live pull request head SHA"
  exit 1
fi
echo "Live head SHA before listing reviews: ${head_sha}"

reviews_json=$(list_reviews)
mapfile -t rows < <(jq -r '
  .[]
  | select(.state == "APPROVED")
  | [(.id | tostring), (.commit_id // "")]
  | @tsv
' <<<"$reviews_json")

to_dismiss=()
for row in "${rows[@]+"${rows[@]}"}"; do
  [ -z "$row" ] && continue
  review_id=${row%%$'\t'*}
  commit_id=${row#*$'\t'}
  if [ "$review_id" = "$row" ]; then
    commit_id=""
  fi

  if [ -n "$commit_id" ] && [ "$commit_id" = "$head_sha" ]; then
    echo "Keeping review ${review_id} on current head ${head_sha}"
    continue
  fi

  if [ -z "$commit_id" ]; then
    echo "::warning::Review ${review_id} has no commit_id; dismissing"
  fi

  head_now=$(fetch_head_sha)
  if [ -n "$commit_id" ] && [ "$commit_id" = "$head_now" ]; then
    echo "Keeping review ${review_id}; commit ${commit_id} matches head ${head_now} at dismiss time"
    continue
  fi

  if [ "$is_dry_run" -eq 1 ]; then
    echo "Dry run: would dismiss review ${review_id}"
    to_dismiss+=("$review_id")
    continue
  fi

  if [ -n "$commit_id" ]; then
    echo "Dismissing review ${review_id} (commit ${commit_id}, head ${head_now})"
  fi
  dismiss_review "$review_id"
done

if [ "$is_dry_run" -eq 1 ] && [ "${#to_dismiss[@]}" -gt 0 ]; then
  post_dry_run_comment "${#to_dismiss[@]}"
fi
