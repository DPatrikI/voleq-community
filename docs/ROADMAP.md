# Roadmap

## 0.1 — Community foundation

- establish repository, package, licensing, and contribution boundaries;
- preserve a command-line build of a proper macOS application;
- provide the minimal Community interface;
- maintain deterministic DSP tests.

## Validation before a public release

- [Implemented; validated on Sennheiser HDB 630 and Apple AirPods Pro 2] Handle synchronized and converted headset paths in regular playback and call mode with the microphone active. Live profile switching while VolEq remains active and broader device coverage remain pending;
- [Implemented; automated validation and owner preset acceptance complete, device matrix pending] Add 20 ms lookahead peak protection and stronger loud-origin reduction without exposing advanced Community controls;
- [Implemented; automated validation plus quiet-speech and instrumental-music
  MacBook listening accepted, broader device matrix pending] Gate upward
  leveling with fully offline speech probability, a learned noise floor, and a
  macOS system-classifier content check;
- [Implemented locally; 117 automated tests, real-model acceptance, and owner
  listening pass; CPU gate and full device matrix pending] Reuse stereo RNNoise
  output for automatic mild suppression only
  during authorized noisy speech, with a separate before-start Community toggle
  that preserves speech-aware leveling when suppression is off. The
  measured 48 kHz stereo cost is 15.60% of one core on the development Mac,
  above the 5% target. The owner accepted 30 ms at 48 kHz on 2026-07-31 so the
  pinned RNNoise two-block wet reconstruction can be aligned without changing
  its source;
- test real Teams, Zoom, Meet, and browser-based sessions;
- test wired output and additional Bluetooth devices;
- test output switching, process disappearance, sleep/wake, and permission recovery;
- improve the stereo RNNoise CPU result to the release target, measure memory
  behavior, and complete the documented 30-minute soak;
- run repeatable loud/quiet speech fixtures and blind A/B listening checks;
- document confirmed compatibility without overstating untested environments.

## Later Community work

- harden device and process lifecycle handling;
- add deterministic audio fixtures and regression metrics;
- add accessible status and recovery guidance;
- add platform adapters only when they can be maintained and tested.

## Premium exploration

Premium development starts only after the Community path is stable enough to validate the shared engine. App Sandbox feasibility for the capture/mute/process/reinject topology must be proven before committing to Mac App Store distribution. Direct signed and notarized distribution remains a fallback.
