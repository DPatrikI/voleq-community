# Licensing model

## Public repository

Unless a file says otherwise, this repository is licensed under the Mozilla Public License 2.0. Each new source file should begin with:

```text
// SPDX-License-Identifier: MPL-2.0
```

MPL-2.0 uses file-level copyleft. If a covered source file is distributed after modification, that file remains available under MPL-2.0. The license also permits covered files to be combined with separate files in a Larger Work under different terms, provided the MPL obligations are met.

Contributions are accepted under the repository's existing license. Contributors certify their right to contribute using a Developer Certificate of Origin sign-off; no Contributor License Agreement is currently required.

## Premium repository

The future Premium repository is intended to keep its original, separate files proprietary while consuming released Community packages. Premium must not silently copy public files into a private fork or remove MPL notices. Any distributed modifications to MPL-covered files must be made available as required by the license.

## Trademarks

MPL-2.0 does not grant rights to contributor trademarks. The VolEq product name, logo, and official visual identity are handled separately in [TRADEMARKS.md](../TRADEMARKS.md).

## Third-party material

Dependencies, test fixtures, icons, fonts, and sample audio must have compatible, documented provenance before they are committed. Do not add copyrighted meeting recordings or unclear audio samples. Prefer original synthetic fixtures or CC0 material.

RNNoise source and model data, and the minimal SpeexDSP resampler subset, are
included under their BSD 3-Clause licenses. Exact revisions, notices, model
checksums, and reproduction instructions are recorded in
[`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md), the dependency
`REVISION` files, `third_party/SOURCE_MANIFEST.sha256`, and the model
`PROVENANCE.md`. Their licenses remain separate
from the repository's MPL-2.0 license. Normal builds do not fetch dependencies
or contact an online service.

This document explains the intended repository policy and is not legal advice. Obtain legal review before commercial App Store distribution or licensing agreements.
