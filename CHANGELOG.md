# Changelog

Notable changes to VolEq Community are recorded here. The project follows
[Semantic Versioning](https://semver.org/); releases before 1.0 may still change
their public interfaces as the supported platform set grows.

## [Unreleased]

Intended for VolEq Community 0.1.1. The application and build versions remain
unchanged until the separate release branch.

### Added

- Dependency-free manual update checks through the latest published GitHub
  Release, available from the application menu, menu-bar popover, and Settings.
- Explicit second-launch consent for optional checks at most once every 24
  hours while VolEq is running.
- Accessible in-app indicators for a newer release without automatic download,
  installation, notifications, or interruption of active leveling.
- A two-phase System Audio Recording gate that verifies real captured samples
  through a temporary unmuted probe before any muting processing path can be
  created or started.
- Native first-use explanation, cancellable access checking, and equivalent
  System Settings / Check Again recovery in the utility window and menu-bar
  popover.

### Fixed

- Denied, silent, timed-out, cancelled, malformed, and ordinary Core Audio
  startup failures now remain stopped with the original audio unchanged when
  cleanup completes, instead of allowing a muting tap to silence playback while
  VolEq appeared active.
- Fresh starts and output-route recovery now reverify access, require complete
  probe teardown before rebuilding, and fail closed if Core Audio refuses it.
- If Core Audio refuses to stop or destroy a probe or processing resource,
  VolEq retains ownership, requires Quit, and does not claim that the original
  audio path was restored.
- Window presentation now treats an already-correct AppKit activation policy as
  success, and switching from the menu bar dismisses the popover before removing
  its status item.

### Privacy

- Audio processing remains local and offline. Manual or consented automatic
  update checks contact GitHub without sending audio, an account identifier, or
  usage telemetry.

## [0.1.0] - 2026-08-06

### Added

- Application-specific and device-wide system-audio capture on macOS.
- Linked-stereo voice leveling with 20 ms lookahead peak protection.
- Offline speech-aware quiet-voice leveling using bundled RNNoise analysis and
  Apple's local SoundAnalysis framework.
- Automatic mild stationary-noise suppression during authorized speech.
- Direct and sample-rate-converted output paths for built-in, wired, and
  Bluetooth devices, including microphone-active call modes.
- Native window and menu-bar presentations with persistent presentation choice.
- Conservative route-change and processing-failure recovery intended to
  restore the original application audio path.
- Deterministic DSP, conversion, allocation, resource, and release-build tests.

### Privacy

- Captured audio is processed locally in memory. VolEq Community has no account,
  telemetry, audio recording, model download, or online speech service.

### Known limitations

- The official v0.1.0 application supports Apple Silicon only.
- v0.1.0 could create its muting capture path before System Audio Recording
  access was verified. Permission denial could therefore silence original
  playback while VolEq incorrectly appeared active; this is the safety defect
  corrected under Unreleased.
- Processing operates on the combined captured mix rather than maintaining a
  separate level for each meeting participant.
- Speech-aware processing supports validated 16, 44.1, and 48 kHz routes.
  Fractional 10 ms rates such as 22.05 kHz are rejected before VolEq replaces
  the original audio.
- Singing can be classified as speech.

[Unreleased]: https://github.com/DPatrikI/voleq-community/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/DPatrikI/voleq-community/releases/tag/v0.1.0
