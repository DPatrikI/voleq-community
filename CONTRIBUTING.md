# Contributing to VolEq

Thank you for helping improve VolEq. Focused bug reports, reproducible audio cases, documentation corrections, tests, and small pull requests are especially useful while the architecture is young.

## Before opening a change

1. Search existing issues to avoid duplicates.
2. For substantial features or package-boundary changes, open an issue first.
3. Do not include private meeting recordings, credentials, proprietary code, or material with unclear licensing.
4. Keep Premium-only product features out of this public repository; see `docs/EDITIONS.md`.

## Development workflow

VolEq uses short-lived branches and pull requests. The `master` branch is protected, kept in a releasable state, and is not used for unfinished work.

1. Create a focused branch from the latest `master`, using a descriptive prefix such as `feat/`, `fix/`, `docs/`, or `test/`.
2. Keep commits reviewable and include the required Developer Certificate of Origin sign-off.
3. Open a pull request into `master` and wait for the required CI checks to pass.
4. Squash-merge the pull request and delete its source branch after the merge.

Published releases are made from `master` and identified by Semantic Versioning tags such as `v0.1.0`. Tags identify release commits; they are not created for ordinary merges.

## Local checks

```sh
./dev doctor
./dev test
./dev build macos
```

`./dev test` runs both the developer-tooling checks and the Swift package tests.

Changes to audio behavior should include deterministic tests and a short explanation of listening validation. Automated tests do not replace real-device listening evidence.

## Developer Certificate of Origin

Every commit must include a `Signed-off-by` line certifying the [Developer Certificate of Origin 1.1](https://developercertificate.org/):

```sh
git commit -s -m "Describe the change"
```

By signing off, you certify that you have the right to submit the contribution under this repository's MPL-2.0 license. This project does not currently require a Contributor License Agreement.

## Pull requests

- Keep each pull request focused.
- Describe user-visible behavior and risks.
- State exactly what you tested and what remains unverified.
- Preserve MPL notices in covered files.
- Expect review of real-time safety for any audio-callback change.
