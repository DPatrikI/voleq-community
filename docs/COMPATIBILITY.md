# Compatibility

VolEq 0.1.1 is released for Apple Silicon and requires macOS 14.2 or newer. The
minimum version is an implementation requirement. Owner-run pre-release use
covered M1 and M4 MacBook Pros, long device-wide sessions, YouTube playback, a
Slack call, Sennheiser HDB 630 microphone-active transitions, and automatic
output-route reconstruction. The broader device matrix below remains retained
v0.1.0 evidence unless a row or section explicitly identifies 0.1.1 evidence.

## Published 0.1.1 artifact

On 2026-09-02, the owner downloaded the public
`VolEq-Community-0.1.1-macOS-arm64.dmg` from GitHub Releases rather than reusing
a local package. The published checksum matched, macOS accepted the signed and
notarized application, and the documented 0.1.0-to-0.1.1 replacement flow
installed and launched the renamed `VolEq.app` successfully.

The public artifact also passed a focused smoke test covering Start, Stop,
original-audio restoration, a manual update check reporting 0.1.1 as current,
one full-system sleep/wake recovery, Window and Menu Bar presentations, and the
**No sound?** recovery guidance. These checks establish the downloadable
artifact and exercised paths; they do not extend compatibility claims to
devices, permission transitions, repeated lifecycle cycles, or accessibility
scenarios that were not part of this focused test.

## Retained physical v0.1.0 matrix

| System | Operating system | Result |
| --- | --- | --- |
| M1 MacBook Pro | macOS Tahoe 26.5.2 | Passed |
| M4 MacBook Pro | macOS Tahoe 26.5 | Passed |

Testing covered both application-specific and device-wide capture with:

- built-in MacBook speakers;
- a 3.5 mm wired output;
- Apple AirPods Pro 2 in regular playback and microphone-active call mode; and
- Sennheiser HDB 630 in regular playback and microphone-active call mode.

Teams, Zoom, and Google Meet in Safari were used for real meetings. Additional
material included videos, instrumental music, clean and noisy speech,
quiet-to-loud transitions, static, and microphone bumps. Window and menu-bar
presentation, keyboard and accessibility states, route switching, captured
process disappearance, stop/quit, and original-audio restoration were
exercised. The longest uninterrupted
session exceeded eight hours. These owner-run checks produced the expected
audio and lifecycle behavior across the tested matrix.

Private meeting recordings are not stored in this repository. Permission
denial/recovery and sleep/wake are excluded from the retained v0.1.0 evidence;
the detailed defects and 0.1.1 changes are recorded in the
[changelog](../CHANGELOG.md). The focused public-artifact evidence above adds
one sleep/wake cycle and both presentation modes for 0.1.1. Permission
revocation, repeated recovery cycles, output changes during sleep, application
loss during sleep, VoiceOver traversal, and a repeated signed-bundle device
matrix remain unclaimed. Automated coverage is not physical compatibility
evidence.

## Audio formats and latency

- Input and output must be mono or stereo 32-bit floating-point PCM.
- Speech-aware processing is validated at 16, 44.1, and 48 kHz.
- Rates where 10 ms is not a whole number of frames, including 22.05 kHz, are
  rejected before audio replacement starts. The original audio remains active.
- Speech-aware processing reports 30 ms DSP latency at 48 kHz, about 31.13 ms at
  44.1 kHz, and 33.0 ms at 16 kHz. Device and route buffering can add latency.
- With speech awareness disabled, the base leveler uses 20 ms lookahead.

## Boundaries

- The official binary is arm64-only. Intel Macs are not supported.
- The current processor levels the combined captured mix. It cannot identify
  meeting participants or retain a separate gain profile for each person.
- Output changes stop processing and, after successful teardown restores the
  original audio path, validate the new route and rebuild the processing path.
  If Core Audio refuses cleanup, VolEq retains ownership and requires Quit
  rather than claiming restoration.
- Device-wide leveling reconstructs the graph after an independent local
  playback watcher confirms that callbacks are progressing while the main
  capture remains exact-zero after playback resumes.
- Sleep/wake and output-route reconstruction can fail safely rather than resume.
  One public 0.1.1 DMG sleep/wake cycle passed; broader recovery combinations
  remain outside the published compatibility evidence.
- Only processes currently producing audio appear in application capture.
- Multichannel layouts fail safely before processing begins.
- Singing may be treated as speech and receive leveling or mild suppression.

Automated evidence and exact DSP measurements are maintained separately in
[VALIDATION.md](VALIDATION.md).
