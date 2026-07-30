#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0

set -euo pipefail

RNNOISE_REVISION="70f1d256acd4b34a572f999a05c87bf00b67730d"
SPEEXDSP_REVISION="7a158783df74efe7c2d1c6ee8363c1e695c71226"
MODEL_ARCHIVE="rnnoise_data-0a8755f8e2d834eff6a54714ecc7d75f9932e845df35f8b59bc52a7cfe6e8b37.tar.gz"
MODEL_ARCHIVE_SHA256="0a8755f8e2d834eff6a54714ecc7d75f9932e845df35f8b59bc52a7cfe6e8b37"
MODEL_SHA256="1b99898350e75656c77d068162fea402afe51eff15dc751989b1e9f53b98bf91"

REPOSITORY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/voleq-speech-deps.XXXXXX")"
trap 'rm -rf "$WORK_DIRECTORY"' EXIT

git clone --quiet https://github.com/xiph/rnnoise.git "$WORK_DIRECTORY/rnnoise"
git -C "$WORK_DIRECTORY/rnnoise" checkout --quiet "$RNNOISE_REVISION"
git clone --quiet https://github.com/xiph/speexdsp.git "$WORK_DIRECTORY/speexdsp"
git -C "$WORK_DIRECTORY/speexdsp" checkout --quiet "$SPEEXDSP_REVISION"

curl --fail --location --silent --show-error \
  "https://media.xiph.org/rnnoise/models/$MODEL_ARCHIVE" \
  --output "$WORK_DIRECTORY/$MODEL_ARCHIVE"
printf '%s  %s\n' "$MODEL_ARCHIVE_SHA256" "$WORK_DIRECTORY/$MODEL_ARCHIVE" | shasum -a 256 --check

tar -xzf "$WORK_DIRECTORY/$MODEL_ARCHIVE" -C "$WORK_DIRECTORY/rnnoise"
(
  cd "$WORK_DIRECTORY/rnnoise"
  clang -O2 -Isrc src/write_weights.c src/parse_lpcnet_weights.c -lm -o dump_weights_blob
  ./dump_weights_blob
)
printf '%s  %s\n' "$MODEL_SHA256" "$WORK_DIRECTORY/rnnoise/weights_blob.bin" | shasum -a 256 --check

cp "$WORK_DIRECTORY/rnnoise/weights_blob.bin" \
  "$REPOSITORY_ROOT/packages/speech/swift/Sources/VolEqSpeech/Resources/rnnoise-model.bin"

echo "Verified the pinned sources and regenerated the RNNoise model."
echo "Review source changes separately before copying a newer upstream revision."

