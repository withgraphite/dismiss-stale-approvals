# dismiss-stale-approvals

A GitHub action to automatically dismiss stale approvals on pull requests.
Unlike the built in GitHub protection, this action will compare the `git range-diff` of the new version against the previous version, and only dismiss approvals if the diff has changed.

## Usage

```yaml
name: tests

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
