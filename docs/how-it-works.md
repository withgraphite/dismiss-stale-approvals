# How dismiss-stale-approvals works

## Purpose

A pull request approval is **stale** when it was submitted for an older version
of the pull request and the proposed code has since changed.

GitHub can dismiss every approval after any new commit. This action is more
selective: it preserves approvals when commits were reorganized or rebased but
their effective changes stayed the same. It dismisses approvals when it cannot
prove that the changes stayed the same.

## Data and system boundaries

The action runs inside a repository's GitHub Actions job. It uses four sources
of data:

1. The GitHub pull request event supplies the repository, pull request number,
   branch, and current head and base commit SHAs.
2. The GitHub Actions API supplies the previous successful run and its
   `dismiss-stale-approvals-shas` artifact.
3. The repository's Git objects supply the commit history needed for
   `git range-diff`.
4. The GitHub Pull Request Reviews API supplies current approvals and accepts
   dismissal requests. The pull request review-request API accepts requests
   for reviewers to look at the pull request again.

The source repository remains the source of truth for commits and reviews. The
artifact is only a pointer to the previously checked head and base commits. It
contains no repository contents or credentials.

## End-to-end flow

### 1. Restore the previous comparison point

[`latest_artifact.sh`](../latest_artifact.sh) finds the latest successful run
of the same workflow for the same pull request. It downloads that run's
artifact and verifies that:

- the artifact has not expired;
- the artifact contains exactly two valid 40-character commit SHAs; and
- the first SHA (the head) equals the `head_sha` of the selected run.

The run's `head_sha` is the commit that run executed against, and GitHub never
changes it. The script does not compare against the `pull_requests[]` entry on
the run. GitHub rewrites that entry's `head.sha` and `base.sha` to the pull
request's *current* head and base after the run finishes, so they no longer
describe the run. The script uses `pull_requests[].number` only to associate
the run with the pull request.

A workflow run records no immutable base SHA, so the second SHA (the base) is
checked only for format. It is trusted because it comes from the artifact
attached to that same run.

If no trustworthy artifact exists, the action treats the pull request as
changed.

### 2. Compare the previous and current pull request

The action fetches the previous and current head and base commits into a
temporary bare Git repository. Credentials are supplied through Git's
ask-pass mechanism and are not stored in the repository URL.

Git calculates a merge base for each version and compares the two commit ranges
with `git range-diff`. [`classify_range_diff.sh`](../classify_range_diff.sh)
parses the result without an early-exit pipeline, so large output cannot be
mistaken for an unchanged pull request.

`git range-diff` does not evaluate merge commits. Therefore
[`classify_pr_change.sh`](../classify_pr_change.sh) conservatively marks the
pull request as changed when either compared range contains a merge commit.

### 3. Store the current comparison point

After a successful comparison, the action writes the current head and base SHAs
to a short-lived artifact. A later run uses this artifact as its previous
comparison point.

Comparison failures do not upload an artifact. If the latest successful
workflow run has no valid artifact, the next run treats the baseline as
missing and therefore treats the pull request as changed.

### 4. Dismiss only stale approvals, then ask for re-review

When the pull request changed,
[`dismiss_approvals.sh`](../dismiss_approvals.sh) reads all review pages from
GitHub. It dismisses an active approval only when the review's commit differs
from the current pull request head.

Dismissing is what stops an approval from counting toward required reviews. It
does not tell the reviewer anything, so after each successful dismissal the
script also re-requests a review from that approver. A reviewer with several
stale approvals is re-requested once. The re-request is a notification, not an
enforcement mechanism: it does not dismiss the existing approval, so it cannot
replace the dismissal.

A failed dismissal fails the job, because the approval would still count. A
failed re-request only produces a warning, because the stale approval is
already dismissed and only the notification was missed. The script skips
approvals whose author is a bot or a deleted account, which GitHub cannot
re-request. In dry-run mode the script re-requests no one and lists the
reviewers it would re-request in its pull request comment.

The script checks the live pull request head before and after reading reviews.
If another push changed the head while an older workflow was running, that
workflow exits without dismissing approvals or re-requesting reviews on the
newer version.

## Decision outcomes

| Condition | Outcome |
| --- | --- |
| Valid comparison proves the ranges are unchanged | Preserve approvals |
| Commit content or structure changed | Dismiss approvals for older commits and re-request review from those approvers |
| Either range contains a merge commit | Treat as changed |
| Baseline is missing, expired, or invalid | Treat as changed |
| Fetch or comparison fails | Treat as changed |
| Pull request head changes while the workflow runs | Let the newer run decide |
| Review dismissal fails | Fail the job so a required check remains blocking |
| Review re-request fails after a dismissal | Warn and continue; the approval is already dismissed |

## Permissions and security

Run the action in a dedicated job that does not execute pull request code. It
requires only:

- `actions: read` to locate previous workflow artifacts;
- `contents: read` to fetch commits; and
- `pull-requests: write` to read and dismiss reviews.

Use the repository-scoped `GITHUB_TOKEN`, never a personal access token. Pin
the action to a reviewed full commit SHA. See the
[root README](../README.md#security-and-rollout) for the recommended workflow.

Pull requests from forks normally receive a read-only token and cannot dismiss
reviews. Repositories that accept untrusted fork pull requests should use
GitHub's native stale-review protection or a separately reviewed design.

## Testing

Run all local checks with:

```bash
./tests/run.sh
```

The runner discovers focused `tests/test_*.sh` files. The current suite covers
range classification, approval selection and races, API pagination, and
artifact integrity. See the [testing section in the README](../README.md#testing)
for contribution guidance.
