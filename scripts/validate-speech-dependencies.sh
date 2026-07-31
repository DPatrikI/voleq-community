#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0

set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODEL="$REPOSITORY_ROOT/packages/speech/swift/Sources/VolEqSpeech/Resources/rnnoise-model.bin"
RNNOISE_REVISION="70f1d256acd4b34a572f999a05c87bf00b67730d"
SPEEXDSP_REVISION="7a158783df74efe7c2d1c6ee8363c1e695c71226"
MODEL_SHA256="1b99898350e75656c77d068162fea402afe51eff15dc751989b1e9f53b98bf91"

require_line() {
  local text="$1"
  local file="$2"
  if ! grep -Fqx "$text" "$file"; then
    echo "error: expected '$text' in ${file#"$REPOSITORY_ROOT/"}" >&2
    exit 1
  fi
}

require_line "Revision: $RNNOISE_REVISION" "$REPOSITORY_ROOT/third_party/rnnoise/REVISION"
require_line "Revision: $SPEEXDSP_REVISION" "$REPOSITORY_ROOT/third_party/speexdsp/REVISION"

(
  cd "$REPOSITORY_ROOT"
  shasum -a 256 --check --status third_party/SOURCE_MANIFEST.sha256
)

for license in \
  "$REPOSITORY_ROOT/third_party/rnnoise/LICENSE" \
  "$REPOSITORY_ROOT/third_party/speexdsp/LICENSE"; do
  test -s "$license"
  grep -Fq "Redistribution and use in source and binary forms" "$license"
done

printf '%s  %s\n' "$MODEL_SHA256" "$MODEL" | shasum -a 256 --check --status
model_size="$(stat -f '%z' "$MODEL")"
if (( model_size < 13000000 || model_size > 15000000 )); then
  echo "error: unexpected full RNNoise model size: $model_size bytes" >&2
  exit 1
fi

echo "[ok] pinned speech sources, licenses, and full model"
