# Changelog

Notable changes to VolEq are recorded here. The project follows
[Semantic Versioning](https://semver.org/); releases before 1.0 may still change
their public interfaces as the supported platform set grows.

## [Unreleased]

No changes yet.

## [0.1.1] - 2026-08-11

### Added

- Dependency-free manual update checks through the latest published GitHub
  Release, available from the application menu, menu-bar popover, and Settings.
- Explicit second-launch consent for optional checks at most once every 24
  hours while VolEq is running.
- Accessible in-app indicators for a newer release without automatic download,
  installation, notifications, or interruption of active leveling.
- A native first-use privacy explanation before the real pipeline asks macOS
  for System Audio Recording access.
- An always-visible **No sound?** help action in both control surfaces, with
  local-only privacy guidance and a direct System Settings action.
- Separate contributor-build identity, so an installed release grant is never
  mistaken for access to a newly ad-hoc-signed source build.
- Proactive system-sleep teardown and bounded wake reconstruction that preserve
  the intended capture mode, processing settings, and application identity.
- A lock-free C11-atomic callback heartbeat with a control-thread watchdog that
  attempts complete teardown before reusing the safe recovery path when
  callbacks stop progressing. If Core Audio refuses cleanup, VolEq retains
  ownership and requires Quit rather than claiming restoration.
- Equivalent accessible Paused for System Sleep, Restoring Leveling, and
  Leveling Did Not Resume states with a user-controlled Try Again action in the
  utility window and menu-bar popover.

### Changed

- The installed open-source application is now named **VolEq**. The repository,
  bundle identifier, source-module names, and Community distribution channel
  remain unchanged; the planned paid application will use the distinct
  **VolEq Pro** name.

### Fixed

- Core Audio startup failures now leave the lifecycle non-running and attempt
  complete cleanup instead of reporting a failed graph as active.
- Audio startup now follows the privacy explanation directly, stays non-running
  until the real processing pipeline starts and callbacks progress, and leaves
  macOS as the authority for System Audio Recording permission.
- If Core Audio refuses to stop or destroy a processing resource,
  VolEq retains ownership, requires Quit, and does not claim that the original
  audio path was restored.
- Window presentation now treats an already-correct AppKit activation policy as
  success, and switching from the menu bar dismisses the popover before removing
  its status item.
- Full system sleep now immediately leaves Active and begins dependent muting-
  graph teardown; wake is coalesced until cleanup finishes, then waits for a
  stable output route before creating a replacement graph.
- VolEq no longer reports Active until callback progress has begun, and a graph
  with no callback progress for two seconds is torn down instead of retaining a
  stale muting path.
- Device-wide leveling now reconstructs the audio graph when an independent
  playback check confirms that the active capture path is still delivering
  exact-zero buffers after playback has resumed.
- Bluetooth and output-route transitions now permit safe reconstruction after
  the processing graph is gone even if an obsolete output listener remains.
- Playback-activity watcher teardown now completes before another audio graph
  is started during Stop, sleep, route changes, termination, or recovery.
- Application capture after wake is restored only by PID plus bundle identity,
  or by one unique exact bundle match; missing or ambiguous targets stop safely
  instead of selecting an unrelated process.

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
- v0.1.0 could report a failed muting capture path as active. Permission denial
  could therefore silence original playback while VolEq incorrectly appeared
  active; this is fixed in 0.1.1.
- v0.1.0 could retain a stale muting Core Audio graph across system sleep while
  still appearing active. The earlier successful sleep/wake evidence is
  withdrawn; 0.1.1 replaces that lifecycle, subject to its separate signed-bundle
  owner validation.
- Processing operates on the combined captured mix rather than maintaining a
  separate level for each meeting participant.
- Speech-aware processing supports validated 16, 44.1, and 48 kHz routes.
  Fractional 10 ms rates such as 22.05 kHz are rejected before VolEq replaces
  the original audio.
- Singing can be classified as speech.

[Unreleased]: https://github.com/DPatrikI/voleq-community/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/DPatrikI/voleq-community/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/DPatrikI/voleq-community/releases/tag/v0.1.0
