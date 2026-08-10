# Compatibility

VolEq Community 0.1.0 is distributed for Apple Silicon and requires macOS 14.2
or newer. The minimum version is an implementation requirement; the physical
release matrix below records the systems that were actually exercised.

## Physical release matrix

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
audio and lifecycle behavior without observed robotic artifacts, unintended
music amplification, clicks, or dropouts.

Private meeting recordings are not stored in this repository. Sleep/wake was
also exercised during v0.1.0 validation, but it is no longer retained as
passing evidence: the owner later reproduced a wake state where VolEq appeared
active while its stale muting graph produced no replacement sound.

The earlier v0.1.0 permission-denial and recovery claim is withdrawn. The owner
later reproduced a denial path that could mute original audio while VolEq
appeared active. The Unreleased 0.1.1 source keeps startup non-running until the
real pipeline has started and callback progress is observed, but denial, grant,
relaunch, route-recovery, sleep/wake, window/menu-bar, and
built-in/wired/Bluetooth cases remain pending signed-bundle owner validation
before they can be added back to the compatibility matrix. When sleep begins,
the Unreleased source immediately leaves Active and starts teardown; wake waits
for that cleanup and a stable route before reconstruction. It also monitors
callback progress. Automated coverage is not physical compatibility evidence.

## Audio formats and latency

- Input and output must be mono or stereo 32-bit floating-point PCM.
- Speech-aware processing is validated at 16, 44.1, and 48 kHz.
- Rates where 10 ms is not a whole number of frames, including 22.05 kHz, are
  rejected before audio replacement starts. The original audio remains active.
- Speech-aware processing reports 30 ms DSP latency at 48 kHz, about 31.13 ms at
  44.1 kHz, and 33.0 ms at 16 kHz. Device and route buffering can add latency.
- With speech awareness disabled, the base leveler uses 20 ms lookahead.

## Boundaries

- The official binary is arm64-only. Intel Macs are not supported by v0.1.0.
- The current processor levels the combined captured mix. It cannot identify
  meeting participants or retain a separate gain profile for each person.
- Output changes stop processing and, after successful teardown restores the
  original audio path, validate the new route and rebuild the processing path.
  If Core Audio refuses cleanup, VolEq retains ownership and requires Quit
  rather than claiming restoration.
- The official v0.1.0 build has a known full-system-sleep recovery defect. The
  Unreleased replacement behavior remains pending signed-bundle owner testing.
- Only processes currently producing audio appear in application capture.
- Multichannel layouts fail safely before processing begins.
- Singing may be treated as speech and receive leveling or mild suppression.

Automated evidence and exact DSP measurements are maintained separately in
[VALIDATION.md](VALIDATION.md).
