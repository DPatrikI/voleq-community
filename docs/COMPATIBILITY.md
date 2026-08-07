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
process disappearance, sleep/wake, stop/quit,
and original-audio restoration were exercised. The longest uninterrupted
session exceeded eight hours. These owner-run checks produced the expected
audio and lifecycle behavior without observed robotic artifacts, unintended
music amplification, clicks, or dropouts.

Private meeting recordings are not stored in this repository.

The earlier v0.1.0 permission-denial and recovery claim is withdrawn. The owner
later reproduced a denial path that could mute original audio while VolEq
appeared active. The Unreleased 0.1.1 source adds an unmuted verification gate,
but denial, grant, relaunch, route-recovery, window/menu-bar, and built-in/wired/
Bluetooth cases remain pending signed-bundle owner validation before they can be
added back to the compatibility matrix.

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
- Output changes stop processing, restore the original route, and require a new
  unmuted access verification before processing can resume.
- Only processes currently producing audio appear in application capture.
- Multichannel layouts fail safely before processing begins.
- Singing may be treated as speech and receive leveling or mild suppression.

Automated evidence and exact DSP measurements are maintained separately in
[VALIDATION.md](VALIDATION.md).
