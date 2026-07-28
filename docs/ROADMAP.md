# Roadmap

## 0.1 — Community foundation

- establish repository, package, licensing, and contribution boundaries;
- preserve a command-line build of a proper macOS application;
- provide the minimal Community interface;
- maintain deterministic DSP tests.

## Validation before a public release

- test real Teams, Zoom, Meet, and browser-based sessions;
- test built-in speakers, wired output, AirPods, and other Bluetooth devices;
- test output switching, process disappearance, sleep/wake, and permission recovery;
- measure CPU, latency, memory behavior, and long-running stability;
- run repeatable loud/quiet speech fixtures and blind A/B listening checks;
- document confirmed compatibility without overstating untested environments.

## Later Community work

- harden device and process lifecycle handling;
- add deterministic audio fixtures and regression metrics;
- add accessible status and recovery guidance;
- add platform adapters only when they can be maintained and tested.

## Premium exploration

Premium development starts only after the Community path is stable enough to validate the shared engine. App Sandbox feasibility for the capture/mute/process/reinject topology must be proven before committing to Mac App Store distribution. Direct signed and notarized distribution remains a fallback.
