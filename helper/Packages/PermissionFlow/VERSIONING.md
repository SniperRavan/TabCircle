# Versioning & Release Policy

> This document applies to the [`lifedever/PermissionFlow`](https://github.com/lifedever/PermissionFlow) fork. Upstream (`jaywcjlove/PermissionFlow`) may have a different release policy — see its own README.

This fork follows [Semantic Versioning](https://semver.org/) and is released exclusively via git tags.

## Recommended dependency declaration

```swift
dependencies: [
    .package(url: "https://github.com/lifedever/PermissionFlow.git", from: "0.1.0")
]
```

Please **do not** pin to a commit revision or a branch:

- `revision:` ties your build to a specific SHA without a visible changelog trail.
- `branch:` lets builds drift as the branch advances, which breaks reproducible CI.

If you genuinely need an unreleased commit (e.g. to pick up an urgent upstream fix), pin `revision:` temporarily and move back to a tag as soon as one is published.

## Version ranges

- **Patch** (`0.1.0 → 0.1.1`): bug fixes only, no public API changes.
- **Minor** (`0.1.0 → 0.2.0`): new API. **While on 0.x, minor bumps may contain breaking changes** — always read the release notes before upgrading.
- **Major** (`0.x → 1.0.0`): once 1.0 ships, standard SemVer applies and breaking changes only land in a major bump.

## Upgrading as a consumer

```bash
swift package update
```

Then **commit both** `Package.swift` and `Package.resolved` together, so CI, local, and release builds all resolve to the same commit.

## Release flow (maintainers)

1. Develop on a feature branch → merge (or fast-forward) to `main`.
2. Tag on `main` with a SemVer version (no `v` prefix): `git tag 0.2.0`.
3. `git push origin main && git push origin 0.2.0`.

The first versioned release is `0.1.0`.
