# Validation

VolEq changes the audio people hear, so a green build is necessary but not sufficient. Every audio-behavior pull request records deterministic checks here and receives listening validation before merge. Private meeting recordings are never committed.

## Lookahead leveling

Branch: `feat/lookahead-leveling`

Automated status: revalidated on 2026-08-02; revised preset accepted by the owner.

| Check | Result |
| --- | --- |
| Developer environment checks | 5 passed |
| Swift package tests | 120 passed |
| Default lookahead at 16 / 44.1 / 48 kHz | 320 / 882 / 960 frames |
| Quiet-to-loud onset | First loud 20 ms no more than 1 dB above settled loud output |
| Full-scale isolated impulse | Caught before output and not amplified |
| Typical program level | −14 dBFS steady input remains within 3 dB of bypass |
| Quiet-origin versus loud-origin speech | Loud-origin fixture remains 0–2 dB below quiet-origin speech |
| Reset and zero-lookahead behavior | Passed |
| Existing Bluetooth conversion and cadence regressions | Passed |
| Strict-concurrency Swift build | Passed without warnings |
| Release app build, ad-hoc signature, and property list | Passed |

The 20 ms figure is the DSP lookahead delay. A route that uses sample-rate conversion can add converter and device buffering latency outside the portable leveler.

The 10 ms candidate was judged to be the right direction. The owner then requested and accepted the 20 ms lookahead on 2026-07-29. On 2026-08-02, owner listening found the processed mix noticeably quieter than bypass, especially for louder material. The default extra 6 dB loud-source reduction was removed while retaining 6:1 compression, quiet-priority leveling, lookahead protection, and the limiter. Automated loudness checks pass. The final release matrix below re-exercised the accepted curve across built-in, wired, and Bluetooth output.

### Listening gate

The 20 ms timing and revised default loudness curve passed the final v0.1.0
physical matrix. Quiet and steady loud speech, quiet-to-loud transitions,
static, microphone bumps, music, clipping, pumping, and start/route-change
behavior were checked on both MacBooks, built-in and wired output, and both
listed Bluetooth headsets in regular and microphone-active modes.

## Speech-aware leveling

Branch: `feat/speech-aware-leveling`

Automated status: complete on 2026-07-31. The final v0.1.0 physical matrix is
complete and recorded below.

| Check | Result |
| --- | --- |
| Developer environment checks / Swift tests | 5 / 85 passed |
| Pinned RNNoise / SpeexDSP revisions, BSD-3 licenses, and full-model checksum | Passed |
| Real offline model loading and checksum rejection | Passed |
| Probability bounds, finite RNNoise output, and resampler-aligned power metadata | Passed |
| 10 ms frame accounting, fresh-state-equivalent reset, reported latency, and checkpointed 1,000-block drift at 16 / 44.1 / 48 kHz | Passed |
| Deterministic open / hysteresis / 200 ms hold / 150 ms fade | Passed |
| Quiet music remains dry through isolated 99% classifier spikes; quiet speech requires two consecutive 90% blocks | Passed |
| macOS content authority keeps RNNoise false positives dry until two system speech results agree | Passed |
| Observed quiet-speech scores (26% / 39% and 61% / 29%) qualify while observed chill music (10% / 43%) remains dry | Passed |
| A 500 ms input gap revokes stale speech permission before new content begins | Passed |
| High-confidence speech below the fixed gate uses the learned-noise margin and receives gain | Passed |
| First-syllable eligibility backfill without preceding-noise gain | Passed |
| Per-sample speech-gain slew and analyzer-only parity with the base leveler | Passed |
| Learned noise floor and static-noise no-boost guarantee | Passed |
| Quiet-speech boost, non-speech dry bypass, and loud-content protection | Passed |
| Startup failure plus one-shot direct / converted runtime recovery and controller stop transition | Passed |
| Existing lookahead, linked stereo, two-way conversion, 48→16 kHz mono call mode, and callback-cadence regressions | Passed |
| Synchronized direct routes feed content analysis at the output rate; converted routes use the input rate | Passed |
| Strict-concurrency build | Passed without warnings |
| Release app, bundled model, ad-hoc signature, and property list | Passed |

The Community preset keeps the accepted 20 ms DSP delay at 16, 44.1, and
48 kHz. Analysis latency fits inside that delay at those rates, so speech
classification adds no further DSP block. Sample-rate conversion and hardware
buffers can still add route-specific latency outside the portable processor.

The deterministic music fixture is preserved after latency alignment when its
injected classification is non-speech. Singing remains a known limitation: it
can be classified as speech. RNNoise denoised samples are not used in this
change, so active suppression still belongs to the later noise-suppression
branch.

The initial physical build sounded strongly robotic on MacBook speakers only
when speech-aware processing was enabled. A three-way A/B run showed that both
the base leveler and RNNoise analysis without applied decisions were clean,
isolating the defect to 10 ms gain changes rather than analyzer callback cost.
After replacing block-edge upward-gain changes with a 30 ms per-sample rise,
while keeping release on the gate's existing 150 ms eligibility fade, the owner
confirmed on 2026-07-30 that all three diagnostic modes
were free of the robotic artifact. The temporary analyzer-only UI control was
then removed; the speech-aware on/off switch remains.

On 2026-07-31, temporary diagnostics isolated quiet-speech gain bouncing to the
fixed -55 dB cutoff: speech measured about -59.8 dB with 99% confidence and an
-81.8 dB learned noise floor, yet upward eligibility was zero. The adaptive
speech floor and quiet hold removed that bouncing in owner listening. The
temporary diagnostics were removed before commit.

On 2026-07-31, owner testing found that RNNoise alone could classify instrumental
music as speech and intermittently raise it. The macOS adapter now uses Apple's
offline system sound classifier as a slower content authority without extending
the 20 ms DSP delay. Temporary measurements separated accepted quiet speech
(26% speech / 39% music and 61% / 29%) from rejected chill music (10% / 43%).
After calibrating that comparison and resetting permission across input gaps,
the owner confirmed that quiet speech was amplified while the tested chill music
remained dry. The temporary content diagnostics were then removed.

### Listening gate

- [x] MacBook speakers: speech-aware on/off and analyzer-only A/B are free of
  the robotic artifact after gain smoothing.
- [x] MacBook speakers, device-wide capture: very quiet speech remains
  continuously leveled across the former -55 dB cutoff.
- [x] MacBook speakers, device-wide capture: tested chill music remains dry while
  quiet speech remains amplified with the macOS content authority enabled.
- [x] MacBook speakers: static, microphone bump, clean speech, speech with
  background noise, music, and quiet-to-loud transitions.
- [x] Sennheiser HDB 630: regular playback and microphone-active call mode.
- [x] Apple AirPods Pro 2: regular playback and microphone-active call mode.
- [x] Confirm stationary noise and unrelated sounds remain unamplified across
  the full scenario matrix.
- [x] Confirm music stays natural and loud speech still receives the accepted
  downward reduction.

The owner completed this physical listening matrix on 2026-07-31 after the
macOS content-authority calibration. No robotic processing, intermittent music
boost, or loss of quiet-speech leveling remained in the accepted build.
The affected synchronized route was retested and accepted after content analysis
was split between the direct output clock and converted input clock.

## macOS frontend and presentation

Automated coverage:

| Check | Evidence |
| --- | --- |
| Presentation preference | Unit tests cover Window defaulting, Menu Bar persistence, and unknown-value fallback |
| Shared presentation metadata | Unit tests require exactly Window and Menu Bar with distinct, complete metadata |
| Menu-bar brand image | Unit tests verify the committed template raster and intrinsic 18-by-18-point `NSImage` size |
| Processing-failure status | Regression tests verify route and process refreshes preserve unrelated failure diagnostics |
| Release resources | The macOS build verifies generated-asset drift, packaged image decoding, the property list, and the ad-hoc signature |
| Developer environment checks / Swift tests | 5 / 139 passed |

The full-color application icon and monochrome status-item mark are generated
deterministically from the original VolEq premium Android icon layers. The
menu-bar regression test verifies template rendering and an intrinsic
18-by-18-point `NSImage` size.

Runtime checks covered presentation switching, utility-window close and reopen,
Settings access, persistence across relaunch, explicit Quit, first-run and
permission-recovery states, processing failures, and keyboard/accessibility
states. The owner completed the release inspection on both validated Macs.

## Mild noise suppression

Automated status: 145 Swift tests pass on 2026-08-05, including authorization,
right-only, anti-phase, reset, allocation, 30 ms latency, real-model marker
alignment, noise reduction, speech projection, stereo balance, and clean-speech
transparency. Five final CPU runs pass the unchanged 5% gate. Owner listening of
the optimized build passed on 2026-08-02 across MacBook speakers, Sennheiser HDB
630, and Apple AirPods Pro 2. The later full release matrix and an uninterrupted
session exceeding eight hours complete the owner acceptance evidence.

| Check | Result |
| --- | --- |
| Developer environment checks / Swift tests | 5 / 145 passed |
| Speech-aware / suppression coupling | The enabled route always prepares stereo suppression for direct and converted paths; disabling speech awareness skips both mono and stereo speech-processor construction and retains base-leveler sample parity |
| Shared immutable model and independent L/R RNNoise state | Passed |
| Ordered-float equivalence | Accepted snapshot remains exact; a 1,000-block stereo/right-only/anti-phase differential stream is bit-exact for events, matching-channel power, probability, SNR metadata, and every L/R wet sample across the supported 16 / 44.1 / 48 kHz routes. The 48 kHz fixture retains the close-boundary assertion of ≤0.001; the recorded 48 kHz run observed 0.00038 |
| Max-channel probability with matching channel power drives linked decisions | Passed against two independent mono states |
| 18 / 21 / 24 dB SNR taper | 50% / 25% / 0% wet |
| Wet transition timing | 30 ms fade in / 100 ms fade out; bounded per-sample slope |
| Seeded scripted-policy fixture with stationary noise | More than 3 dB noise reduction; projected speech change no more than 1 dB |
| Bundled-RNNoise seeded broadband-noise fixture | At least 3 dB noise reduction, projected speech change no more than 1 dB, stereo-balance change no more than 0.5 dB |
| Bundled-RNNoise clean speech | Level change no more than 0.1 dB; residual error below -28 dB relative to speech |
| Music and sustained non-speech | Sample-for-sample dry after release |
| Linked stereo balance | Change no more than 0.5 dB |
| First warm-up blocks, non-finite input/wet samples, impossible wet ranges, and corrupt-processing recovery | Passed; warm-up is dry and failure is one-shot/silent |
| Fresh-state reset, extreme finite input, 1,000-block stereo FIFO/source-index streams, and resampler drift at 16 / 44.1 / 48 kHz | Passed with conservative extreme-input failure and finite output |
| First, resolved, and warmed direct/converted callbacks | Zero allocations for speech-aware stereo processing at 16 / 44.1 / 48 kHz, including both Speex resamplers and a converted 44.1→48 kHz route; contended settings/failure locks are skipped and factories are not called |
| Route-change lifecycle | Teardown followed by fresh rate-specific stereo states and resumed finite 16 kHz processing passed |
| Existing lookahead, limiter, downward compression, stereo linking, converted routes, 48→16 kHz call mode, cadence, and content-analysis rates | Passed |
| Strict-concurrency build with warnings as errors | Passed |
| Independent RNNoise wet alignment review | Finding fixed: main reconstruction is tagged `k - 2`; exact source-block markers and zero-lag seeded broadband correlation pass at all supported rates |
| 48 kHz stereo release benchmark | **Passed target:** final post-review runs at 4.54% / 4.49% / 4.51% / 4.51% / 4.51% of one core; every run ≤5% |
| Release app, ad-hoc signature, property list, and patch whitespace | Passed |

The v0.1.0 release-branch rerun on the M1 MacBook Pro measured 4.60% of one
core (2.758 seconds of thread CPU for 60 seconds of represented audio), within
the unchanged 5% target. The full 145-test suite, strict-concurrency release
build with warnings as errors, generated-resource checks, packaged-model checks,
release metadata validation, property-list validation, and ad-hoc application
signature all passed on 2026-08-05.

The implementation's reported DSP latency includes measured Speex input and
output delay:

| Source rate | Speex input / output delay | Total DSP delay |
| --- | --- | --- |
| 16 kHz | 24 / 24 frames | 528 frames / 33.0 ms |
| 44.1 kHz | 24 / 26 frames | 1,373 frames / about 31.13 ms |
| 48 kHz | none | 1,440 frames / 30.0 ms |

The validated speech route matrix is 16, 44.1, and 48 kHz. Fixed-block speech
analysis now rejects 22,050 Hz and other rates where 10 ms is not a whole
number of source frames before processing starts. Unsupported speech-aware
startup leaves the original audio path intact; fractional-cadence support is
not part of v0.1.0. This is automated initialization and lifecycle coverage,
not physical testing of a 22.05 kHz device.

RNNoise source inspection and an independent impulse check showed output block
0 silent, output block 1 about 34 dB below the main reconstruction, and the main
source-block-0 reconstruction in output block 2. The implementation now treats
both initial blocks as warm-up, tags wet output two blocks back, and compares SNR
against the matching dry analysis block. The owner authorized 30 ms at 48 kHz
on 2026-07-31. Real-model source-block marker tests pass after the correction.

### CPU benchmark and profiling evidence

The canonical benchmark is warmed after reset, release-mode, 48 kHz stereo, and
measures the complete `DynamicsProcessor` thread CPU time divided by 60 seconds
of represented audio. Release Swift uses `-O` with whole-module optimization;
the RNNoise C target uses the release C optimizer and the Apple-Silicon float
path uses NEON/FMA. Two independent RNNoise states process every 480 samples.
The timed region excludes building, wall-clock scheduling, Core Audio traversal,
and the slower content-analysis queue. Runtime guards reject debug execution,
unexpected 480/1,440-frame workload latency, processing failure, non-finite
measurement, a silent/non-executing output path, or anything other than exactly
6,000 successful paired RNNoise frames. The fixture, duration, and 5% target are
unchanged.

Baseline evidence on `acd4690`, after one discarded 15.01% warm-up, was 14.95%,
14.87%, 14.94%, 14.92%, and 14.85%. Median was 14.92%, minimum 14.85%, maximum
14.95%, and spread 0.10 percentage point (about 0.67% of the median), so no
thermal-variation extension was needed.

`sample` and Instruments Time Profiler both placed the dominant cost in the
scalar fallback used by RNNoise's sparse float GRU matrices: 5,492 of the
baseline `sample` top-of-stack samples were in `rnn_compute_linear_c`. FFT,
pitch search, feature extraction, Swift/C calls, copying/FIFO work, dynamics,
and resampling were individually much smaller. The callback-allocation harness
also represented buffer integration and later passed with zero allocations.

The retained changes replace that scalar sparse kernel with NEON, pair the two
float inference passes so sparse GRU and dense/conv weights are loaded once,
interleave independent output rows without changing any output's accumulation
order, pair the high-pass traversal, fuse stereo power traversal, rotate
already-allocated history buffers, prepare direct 48 kHz wet blocks without a
redundant FIFO round trip, and use explicitly preallocated callback-owned DSP
and delay buffers to avoid Swift copy-on-write/exclusivity overhead. An experiment
using RNNoise's bundled int8 weights reached 4.13% but was rejected: comparison
showed up to 0.706 probability, 13.5 dB SNR, and 0.0413 normalized-sample drift.
No quantized weights remain in the optimized path.

The final post-review canonical set on 2026-08-04 measured 4.54%, 4.49%,
4.51%, 4.51%, and 4.51% (2.726 / 2.697 / 2.704 / 2.705 / 2.708 thread-CPU
seconds). Median was 4.51%, minimum 4.49%, maximum 4.54%, and spread 0.05
percentage point. Every recorded run passes the unchanged 5% gate. No new
Instruments or physical-listening result is claimed for this architecture-only
refactor; the prior accepted listening and profiling records remain separate
historical evidence.

Refactor comparison evidence collected on 2026-08-04 used the same release
fixture and hardware. Five clean-master runs at `1e8076c` measured 4.30%,
4.41%, 4.31%, 4.39%, and 4.37% (mean 4.356%); five final post-review runs
measured 4.54%, 4.49%, 4.51%, 4.51%, and 4.51% (mean 4.512%). The unchanged 5% gate
passed in every run. The accepted deterministic RNNoise snapshot and the
existing 1,000-block scalar-versus-paired differential stream also passed both
states; no new physical listening or soak evidence is claimed for this
architecture-only change.

## Physical v0.1.0 release evidence

The owner completed multi-hour testing on two separate Apple Silicon systems:

| System | Operating system |
| --- | --- |
| M1 MacBook Pro | macOS Tahoe 26.5.2 |
| M4 MacBook Pro | macOS Tahoe 26.5 |

Physical coverage included Teams, Zoom, and Google Meet in Safari; built-in
speakers; 3.5 mm output; AirPods Pro 2; and Sennheiser HDB 630. Both Bluetooth
devices were exercised in regular playback and microphone-active call mode.
Application-specific and device-wide capture, live route switching, captured
process loss, sleep/wake, permission denial and recovery, frontend,
accessibility and failure states, videos, music, clean and noisy speech,
quiet-to-loud transitions, static, and microphone bumps produced the expected
results. Stop and quit restored the original audio path.

The longest uninterrupted session exceeded eight hours. No robotic processing,
unintended music amplification, clicks, dropouts, or unbounded behavior were
observed during the owner-run sessions. This is perceptual and lifecycle
evidence, not a substitute for the deterministic tests or the canonical CPU
benchmark above; private recordings and sensitive meeting content were not
retained.

The release claim is limited to the exact matrix above. No Intel Mac support or
untested-device compatibility is implied. See
[COMPATIBILITY.md](COMPATIBILITY.md) for the concise user-facing matrix and
remaining format and behavior boundaries.
