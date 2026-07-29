# VolEq — Volume Equilibrium

VolEq automatically levels incoming voice volume so quiet speakers are easier to hear and loud speakers are less overwhelming.

This repository contains **VolEq Community**, the open-source edition. It is macOS-first, with platform-neutral core and DSP packages designed for future platform adapters.

> [!IMPORTANT]
> VolEq is early-stage software. The package builds and its DSP tests pass, but it has not yet completed real-world validation across meeting apps, output devices, Bluetooth transitions, latency, and long-running sessions.

## Community edition

The Community app intentionally has a small surface:

- turn voice leveling on or off;
- attach to one currently active application or the device-wide output mix;
- use a fixed, safe speech-leveling preset.

The source is open for inspection, modification, and contribution. VolEq Premium is planned as a separately distributed application with advanced controls, profiles, automation, automatic switching, and commercial support. See [the edition boundary](docs/EDITIONS.md).

## Requirements

- macOS 14.2 or newer;
- Xcode or Apple Command Line Tools with Swift 5.10 or newer;
- System Audio Recording permission when macOS asks on first use.

## Build and run

Check the local toolchain:

```sh
./dev doctor
```

This validates the minimum macOS and Swift versions, the selected Apple developer directory, and the active macOS SDK. It exits with a clear error when the machine is not ready to build VolEq.

Run tests and build a proper ad-hoc-signed macOS application:

```sh
./dev test
./dev build macos
```

Build and launch it:

```sh
./dev run macos
```

The application is assembled at `dist/VolEq Community.app`.

## How it works

On macOS 14.2+, VolEq uses Core Audio process taps to capture an application's outgoing audio, applies linked-stereo speech leveling, and sends the result to the current default output device. The original selected audio is muted only while VolEq is actively replacing it. Device-wide mode excludes VolEq itself to avoid a feedback loop.

VolEq measures the aggregate device's input and output cadence against Core Audio's host timestamps, including any drift compensation Core Audio already applies to a Bluetooth tap. When those measurements show that Core Audio has synchronized the route, VolEq bypasses duplicate conversion even if the stream labels still advertise different nominal rates. When they confirm that conversion remains necessary, VolEq converts the processed stream through Audio Converter Services with fixed-capacity real-time input and output FIFOs, so the device receives complete periods after a short pre-roll. It observes default-device, format, sample-rate, and device-availability changes and safely rebuilds the private audio path after a headset or output-route transition.

No virtual audio driver or permanent system-wide output-device change is required.

## Current limitations

- Output changes trigger an automatic reconnect and can produce a brief silence while Core Audio settles the new route.
- Only processes currently producing audio appear in the application selector.
- The current path supports mono or stereo 32-bit floating-point PCM and converts differing capture/output sample rates. Multichannel layouts fail safely before processing starts.
- The Sennheiser HDB 630 and Apple AirPods Pro 2 have been physically validated in regular playback and call mode with their microphones active. Deterministic tests cover 48↔44.1 kHz and 48→16 kHz paths, but live profile switching while VolEq remains active, broader headset compatibility, meeting apps, CPU usage, latency, and long-running stability still need structured validation.
- The current mixed-stream processor levels the combined incoming audio. It cannot identify individual meeting participants or keep a separate profile for each speaker.

## Repository map

```text
apps/macos/community/     Community macOS app and bundle resources
packages/core/swift/      Platform-neutral product settings and types
packages/dsp/swift/       Platform-neutral speech-leveling DSP
platforms/macos/          Core Audio capture and output adapter
scripts/                  Developer build helpers
docs/                     Architecture, editions, licensing, and roadmap
```

Read [ARCHITECTURE.md](docs/ARCHITECTURE.md) before changing package boundaries.

## Contributing

Bug reports and focused pull requests are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) and sign commits using the Developer Certificate of Origin sign-off described there.

## License and name

Source and documentation in this repository are licensed under the [Mozilla Public License 2.0](LICENSE), unless a file says otherwise. MPL-2.0 is file-level copyleft: modifications to covered files remain open, while separate files may be combined into a larger proprietary work subject to the license terms.

The **VolEq** name and logo are not licensed under MPL-2.0. See [TRADEMARKS.md](TRADEMARKS.md). This is a project policy summary, not legal advice.

## Apple APIs

- [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
- [`AudioHardwareCreateProcessTap`](https://developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap(_:_:))
- [`CATapMuteBehavior`](https://developer.apple.com/documentation/coreaudio/catapmutebehavior)
- [`AudioHardwareCreateAggregateDevice`](https://developer.apple.com/documentation/coreaudio/audiohardwarecreateaggregatedevice(_:_:))
