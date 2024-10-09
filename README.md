# dismiss-stale-approvals

A GitHub action to automatically dismiss stale approvals on pull requests.
Unlike the built in GitHub protection, this action will compare the `git range-diff` of the new version against the previous version, and only dismiss approvals if the diff has changed.

## Usage

1. Add the below worklow to your repository's `.github/workflows` directory.
2. Ensure that the "Dismiss stale pull request approvals" check is required for pull requests, which will ensure that PRs cannot be merged until the action has run successfully.

You can make the check required with either:
- Branch protection rules ([see here](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/managing-a-branch-protection-rule))
- Rulesets ([see here](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/creating-rulesets-for-a-repository))

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
