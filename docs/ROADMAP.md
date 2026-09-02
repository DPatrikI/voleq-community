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
Sennheiser HDB 630, regular and microphone-active Bluetooth modes, selected
lifecycle cases, UI/accessibility states, and sessions exceeding eight hours.
The later reproduced sleep/wake and permission-denial failures withdraw those
specific v0.1.0 passing claims. A focused public 0.1.1 DMG test now covers one
sleep/wake recovery and the documented installation and smoke-test path;
broader replacement evidence remains explicitly scoped below.

The exact tested scope and explicit non-claims are recorded in
[COMPATIBILITY.md](COMPATIBILITY.md); automated and physical evidence remain
separate in [VALIDATION.md](VALIDATION.md).

## 0.1.1 — Safety recovery and automatic update checks

- [x] Tear down the muting Core Audio graph proactively before system sleep and
  rebuild only after a stable output route and fresh target validation.
- [x] Add callback-progress monitoring and route sleep, wake, output changes,
  and stalls through one serialized recovery coordinator.
- [x] Add independently confirmed device-wide recovery when callbacks continue
  but the active capture path remains exact-zero after playback resumes.
- [x] Preserve application identity, device-wide intent, processing settings,
  cancellation, and fail-safe retry behavior through deterministic tests.
- [x] Validate the exact public 0.1.1 DMG checksum, signed/notarized installation,
  0.1.0 replacement flow, Start/Stop restoration, one sleep/wake cycle, both
  presentations, current-version update result, and **No sound?** guidance.
- [ ] Extend signed-bundle evidence to permission revocation, repeated recovery
  cycles, output changes and application loss during sleep, VoiceOver, and the
  broader device matrix.

- [x] Add dependency-free manual checks through the latest published GitHub
  Release.
- [x] Add explicit one-time consent and optional once-per-24-hour checks while
  VolEq is running.
- [x] Keep update networking in the Community macOS shell and isolated from the
  audio, DSP, and speech packages.
- [x] Expose native update actions and accessible background indicators in
  Window, Menu Bar, and Settings surfaces.
- [x] Add deterministic version, parsing, networking, scheduling, persistence,
  concurrency, and presentation-state tests with no live GitHub dependency.
- [x] Validate manual current-version feedback and Window and Menu Bar access in
  the exact public 0.1.1 artifact.
- [ ] Extend owner-facing update evidence to second-launch consent, VoiceOver,
  and rendered offline behavior.

## Later Community work

- harden device and process lifecycle handling;
- add deterministic audio fixtures and regression metrics;
- continue accessibility and recovery-guidance refinement;
- add the planned Windows and Linux adapters only when their native routing
  backends can be maintained and tested.

## VolEq Pro exploration

VolEq Pro development starts only after the open-source VolEq path is stable
enough to validate the shared engine. App Sandbox feasibility for the
capture/mute/process/reinject topology must be proven before committing to Mac
App Store distribution. Direct signed and notarized distribution remains a
fallback.
