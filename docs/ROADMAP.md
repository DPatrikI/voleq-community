# Roadmap

## 0.1 — Community foundation

- [x] Establish repository, package, licensing, and contribution boundaries.
- [x] Preserve a command-line build of a proper macOS application.
- [x] Provide the minimal Community interface.
- [x] Maintain deterministic DSP tests.
- [x] Add Developer ID signing, notarization, and a dependency-free DMG release
  workflow.

## 0.1 release validation

Complete for v0.1.0. Automated checks cover lookahead, speech classification,
suppression, conversion, failure recovery, callback allocation, resources, and
the 5% CPU gate. Owner-run physical validation covers M1 and M4 MacBook Pros,
Teams, Zoom, Google Meet in Safari, built-in and wired output, AirPods Pro 2,
Sennheiser HDB 630, regular and microphone-active Bluetooth modes, lifecycle
recovery, UI/accessibility states, and sessions exceeding eight hours.

The exact tested scope and explicit non-claims are recorded in
[COMPATIBILITY.md](COMPATIBILITY.md); automated and physical evidence remain
separate in [VALIDATION.md](VALIDATION.md).

## Later Community work

- harden device and process lifecycle handling;
- add deterministic audio fixtures and regression metrics;
- continue accessibility and recovery-guidance refinement;
- add platform adapters only when they can be maintained and tested.

## Premium exploration

Premium development starts only after the Community path is stable enough to validate the shared engine. App Sandbox feasibility for the capture/mute/process/reinject topology must be proven before committing to Mac App Store distribution. Direct signed and notarized distribution remains a fallback.
