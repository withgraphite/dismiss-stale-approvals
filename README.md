# dismiss-stale-approvals

A GitHub action to automatically dismiss stale approvals on pull requests.
Unlike the built in GitHub protection, this action will compare the `git range-diff` of the new version against the previous version, and only dismiss approvals if the diff has changed.

## Usage

1. Add the below workflow to your repository's `.github/workflows` directory.
2. Ensure that this GitHub Action is required for pull requests, which will ensure that PRs cannot be merged until the action has run successfully.
![Screenshot of selecting the `dismiss-stale-approvals` action as a required check](./images/required-status-check.png)

You can make the check required with either:
- Branch protection rules ([see here](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/managing-a-branch-protection-rule))
- Rulesets ([see here](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/creating-rulesets-for-a-repository))

See the [example repository](https://github.com/withgraphite/dismiss-stale-approvals-example-repo) for a complete example.

```yaml
name: Dismiss stale pull request approvals

on:
  pull_request:
    types: [
        opened,
        synchronize,
        reopened,
      ]


permissions:
  actions: read
  contents: read
  pull-requests: write

jobs:
  dismiss_stale_approvals:
    runs-on: ubuntu-latest
    steps:
      - name: Dismiss stale pull request approvals
        uses: withgraphite/dismiss-stale-approvals@main
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

## Custom filter command

Use the `filter-command` input to run a custom command when changes are detected. The command receives the `git range-diff` output on stdin and via the `DSA_RANGE_DIFF` environment variable. Additional env vars (`DSA_HEAD_SHA`, `DSA_BASE_SHA`, `DSA_PREV_HEAD_SHA`, `DSA_PREV_BASE_SHA`, `DSA_MERGE_BASE`, `DSA_PREV_MERGE_BASE`) provide commit SHAs for running your own git commands.

**Exit code convention:**
- **Exit 0**: changes are **not** meaningful — keep approvals
- **Non-zero**: changes **are** meaningful (or an error occurred) — dismiss approvals

This fail-closed design ensures that if the filter command errors, approvals are dismissed as a safety default.

### Example: Use Claude to evaluate changes

```yaml
jobs:
  dismiss_stale_approvals:
    runs-on: ubuntu-latest
    steps:
      - name: Dismiss stale pull request approvals
        uses: withgraphite/dismiss-stale-approvals@main
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          filter-command: |
            claude -p "You are reviewing a git range-diff from a pull request.
            Determine if the changes are meaningful enough to require re-approval.
            Trivial changes include: whitespace, comments, formatting, dependency
            lock file updates, and auto-generated file changes.
            If ALL changes are trivial, exit with code 0.
            If ANY changes are meaningful, exit with code 1.
            Here is the range-diff:"
```

### Example: Ignore changes to specific files

```yaml
          filter-command: |
            git diff "$DSA_MERGE_BASE".."$DSA_HEAD_SHA" --name-only \
              | grep -vE '(\.lock$|\.generated\.)' \
              | grep -q . && exit 1 || exit 0
```

This keeps approvals (exit 0) when the only changed files match the exclusion pattern, and dismisses (exit 1) when other files are also changed.

## Issues and contributions

We (the Graphite team) have limited staffing in this area (mainly due to the need for DSA being a relatively small number of customers), which is why the action is OSS in the first place. It was an issue an enterprise customer asked us for input on while trialing so we created it as the simplest possible solution for the problem as a proof-of-concept. We don't expect it to solve the problem for every single Graphite customer exactly as implemented, which is why some of our other larger customers have forked the repo for their desired use.

Feel free to fork to fit your exact use case, and we'd love back-contributions if you feel they'd be useful for others. Keep in mind that a change may work best as an optional configuration for the action, depending on exactly what the change is, of course.

If we don't respond on GitHub immediately to an issue or PR, feel free to bring it to our attention in our [Community Slack server](community.graphite.com).

## Lack of license

This repository is public source, but protected by copyright per GitHub defaults ([see here](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository#choosing-the-right-license)). Graphite customers have express permission to use this action or a fork in their repositories by default. 
