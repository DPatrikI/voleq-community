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

## Local performance patch

VolEq carries a reviewed local divergence from the pinned RNNoise revision for
Apple-Silicon stereo processing. The ARM NEON sparse float matrix path replaces
the upstream scalar fallback, and an internal paired entry point evaluates two
independent recurrent states while reusing immutable weight loads across sparse
GRU, dense, and convolution layers. The paired kernels interleave independent
output rows but retain the accepted accumulation order for every output. A
1,000-block stereo/right-only/anti-phase differential test is bit-exact for
events, linked source selection and power, probability, SNR metadata, and every
denoised sample in both debug and release-optimized builds. The downstream
18/21/24 dB wet-mix decision is therefore unchanged.

The two states retain separate feature, recurrent, gain, probability, synthesis,
and history storage. No model data is changed, no frame is skipped, and the
provided quantized model path is not used. Updated local-source checksums are
recorded in `third_party/SOURCE_MANIFEST.sha256`; the upstream revision and model
checksum above remain unchanged.
