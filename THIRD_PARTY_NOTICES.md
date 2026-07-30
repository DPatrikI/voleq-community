# Third-party notices

VolEq includes the following source dependencies and model data. They are
vendored so normal builds and the finished app remain fully offline.

## RNNoise

- Copyright (c) 2007-2017, 2024 Jean-Marc Valin
- Copyright (c) 2023 Amazon
- Copyright (c) 2017 Mozilla
- Copyright (c) 2005-2017 Xiph.Org Foundation
- Copyright (c) 2003-2004 Mark Borgerding
- Upstream: <https://github.com/xiph/rnnoise>
- Revision: `70f1d256acd4b34a572f999a05c87bf00b67730d`
- License: BSD 3-Clause; full text in `third_party/rnnoise/LICENSE` in the
  source tree and `RNNoise-LICENSE.txt` in the application resources

The bundled full RNNoise model was generated from Xiph's published model data.
Its upstream archive, checksums, and reproduction instructions are recorded in
`packages/speech/swift/Sources/VolEqSpeech/Resources/PROVENANCE.md`.

## SpeexDSP resampler

- Copyright 2002-2008 Xiph.org Foundation and contributors
- Upstream: <https://github.com/xiph/speexdsp>
- Revision: `7a158783df74efe7c2d1c6ee8363c1e695c71226`
- License: BSD 3-Clause; full text in `third_party/speexdsp/LICENSE` in the
  source tree and `SpeexDSP-LICENSE.txt` in the application resources

Only the portable floating-point resampler subset is included. The complete
copyright notice and license text is retained in
`third_party/speexdsp/LICENSE`.

Apple frameworks are used through the macOS SDK and are governed by Apple's
applicable terms.
