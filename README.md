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

## Issues and contributions

We (the Graphite team) have limited staffing in this area (mainly due to the need for DSA being a relatively small number of customers), which is why the action is OSS in the first place. It was an issue an enterprise customer asked us for input on while trialing so we created it as the simplest possible solution for the problem as a proof-of-concept. We don't expect it to solve the problem for every single Graphite customer exactly as implemented, which is why some of our other larger customers have forked the repo for their desired use.

Feel free to fork to fit your exact use case, and we'd love back-contributions if you feel they'd be useful for others. Keep in mind that a change may work best as an optional configuration for the action, depending on exactly what the change is, of course.

If we don't respond on GitHub immediately to an issue or PR, feel free to bring it to our attention in our [Community Slack server](community.graphite.com).
