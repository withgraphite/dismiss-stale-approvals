# Merge Queue Batching Feature Gating

## Status

Batching in Graphite's merge queue is currently available in **private beta**.

## Access Requirements

To enable the batching feature (the "Where CI should run" option under "CI Settings" in the merge queue settings sidebar), you must:

1. Contact Graphite support to request access
2. Visit: https://graphite.dev/contact-us

## What is Batching?

Batching is a merge queue optimization where multiple PRs are grouped together into a temporary combined PR. CI runs on this combined PR, and if all tests pass, all PRs in the batch are merged together. This approach:

- Reduces CI costs by running fewer CI jobs
- Increases merge throughput by processing multiple PRs at once
- Maintains stability by ensuring tests pass at head on the trunk branch

## Configuration

Once access is granted, you can:
- Enable batching in your merge queue settings
- Customize the batch size for each repository based on your desired throughput

## Considerations

Batching is not recommended for repositories that require every single commit in history to build correctly, as the individual commits from each PR are merged together without running CI on each one separately.

---

**Source**: Graphite Merge Queue Optimizations documentation (as of October 2025)
