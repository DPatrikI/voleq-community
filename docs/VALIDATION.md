# Validation

VolEq changes the audio people hear, so a green build is necessary but not sufficient. Every audio-behavior pull request records deterministic checks here and receives listening validation before merge. Private meeting recordings are never committed.

## Lookahead leveling

Branch: `feat/lookahead-leveling`

Automated status: complete on 2026-07-29.

| Check | Result |
| --- | --- |
| Developer environment checks | 5 passed |
| Swift package tests | 36 passed |
| Default lookahead at 16 / 44.1 / 48 kHz | 320 / 882 / 960 frames |
| Quiet-to-loud onset | First loud 20 ms no more than 1 dB above settled loud output |
| Full-scale isolated impulse | Caught before output and not amplified |
| Quiet-origin versus loud-origin speech | At least 5 dB separation in the deterministic fixture |
| Reset and zero-lookahead behavior | Passed |
| Existing Bluetooth conversion and cadence regressions | Passed |
| Strict-concurrency Swift build | Passed without warnings |
| Release app build, ad-hoc signature, and property list | Passed |

The 20 ms figure is the DSP lookahead delay. A route that uses sample-rate conversion can add converter and device buffering latency outside the portable leveler.

The 10 ms candidate was judged to be the right direction. The owner then requested and accepted the 20 ms preset on 2026-07-29. The acceptance did not identify a device or enumerate the scenarios covered, so the release matrix below remains pending rather than inferring evidence.

### Listening gate

The preset decision is accepted. The following broader release checks remain pending:

- [ ] MacBook speakers: quiet speech, steady loud speech, and quiet-to-loud transition.
- [ ] Sennheiser HDB 630: regular playback and microphone-active call mode.
- [ ] Apple AirPods Pro 2: regular playback and microphone-active call mode.
- [ ] Static background, a microphone bump, clean speech, and music.
- [ ] Confirm that loud sections are sufficiently reduced without pumping or audible clipping.
- [ ] Confirm that the initial 20 ms silence is not perceptible as a start or route-change defect.

The earlier Bluetooth routing implementation was listened to successfully on both listed headsets in regular and call modes. That is routing evidence only; it does not count as acceptance of the new lookahead behavior.

## Speech-aware leveling

Branch: `feat/speech-aware-leveling`

Automated status: complete on 2026-07-31; MacBook-speaker regression fixes
accepted, broader physical listening pending.

| Check | Result |
| --- | --- |
| Developer environment checks / Swift tests | 5 / 75 passed |
| Pinned RNNoise / SpeexDSP revisions, BSD-3 licenses, and full-model checksum | Passed |
| Real offline model loading and checksum rejection | Passed |
| Probability bounds, finite RNNoise output, and resampler-aligned power metadata | Passed |
| 10 ms frame accounting, fresh-state-equivalent reset, reported latency, and checkpointed 1,000-block drift at 16 / 44.1 / 48 kHz | Passed |
| Deterministic open / hysteresis / 200 ms hold / 150 ms fade | Passed |
| Quiet-speech low-confidence rescue, learned-floor override, and 600 ms hold without louder music gain | Passed |
| High-confidence speech below the fixed gate uses the learned-noise margin and receives gain | Passed |
| First-syllable eligibility backfill without preceding-noise gain | Passed |
| Per-sample speech-gain slew and analyzer-only parity with the base leveler | Passed |
| Learned noise floor and static-noise no-boost guarantee | Passed |
| Quiet-speech boost, non-speech dry bypass, and loud-content protection | Passed |
| Startup failure plus one-shot direct / converted runtime recovery and controller stop transition | Passed |
| Existing lookahead, linked stereo, two-way conversion, 48→16 kHz mono call mode, and callback-cadence regressions | Passed |
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

### Listening gate

- [x] MacBook speakers: speech-aware on/off and analyzer-only A/B are free of
  the robotic artifact after gain smoothing.
- [x] MacBook speakers, device-wide capture: very quiet speech remains
  continuously leveled across the former -55 dB cutoff.
- [ ] MacBook speakers: static, microphone bump, clean speech, speech with
  background noise, music, and quiet-to-loud transitions still need the full
  scenario matrix.
- [ ] Sennheiser HDB 630: regular playback and microphone-active call mode.
- [ ] Apple AirPods Pro 2: regular playback and microphone-active call mode.
- [ ] Confirm stationary noise and unrelated sounds remain unamplified across
  the full scenario matrix.
- [ ] Confirm music stays natural and loud speech still receives the accepted
  downward reduction.

## Release validation backlog

Before `v0.1.0`, test Teams, Zoom, Meet, browser meetings, wired output, live route switching, process disappearance, sleep/wake, permission recovery, CPU use, memory behavior, and long-running stability. Compatibility claims must distinguish automated coverage from physical-device evidence.
