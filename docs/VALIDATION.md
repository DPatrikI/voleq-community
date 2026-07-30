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

## Release validation backlog

Before `v0.1.0`, test Teams, Zoom, Meet, browser meetings, wired output, live route switching, process disappearance, sleep/wake, permission recovery, CPU use, memory behavior, and long-running stability. Compatibility claims must distinguish automated coverage from physical-device evidence.
