# RNNoise model provenance

- Upstream archive: `https://media.xiph.org/rnnoise/models/rnnoise_data-0a8755f8e2d834eff6a54714ecc7d75f9932e845df35f8b59bc52a7cfe6e8b37.tar.gz`
- Archive SHA-256: `0a8755f8e2d834eff6a54714ecc7d75f9932e845df35f8b59bc52a7cfe6e8b37`
- Generated `rnnoise-model.bin` SHA-256: `1b99898350e75656c77d068162fea402afe51eff15dc751989b1e9f53b98bf91`
- Generator revision: RNNoise `70f1d256acd4b34a572f999a05c87bf00b67730d`
- Generator command: `clang -O2 -Isrc src/write_weights.c src/parse_lpcnet_weights.c -lm -o dump_weights_blob`

The model is the full upstream RNNoise model. It is loaded from this local
resource at startup; VolEq does not download a model while building or running.
Run `scripts/update-speech-dependencies.sh` manually to fetch the pinned source
trees, reproduce the model, verify both upstream checksums, and replace the
local model. Vendored source selection and local integration patches are
reviewed and copied separately; regenerate `third_party/SOURCE_MANIFEST.sha256`
after accepting any source update.
