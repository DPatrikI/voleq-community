# VolEq — Volume Equilibrium

VolEq automatically levels incoming voice volume so quiet speakers are easier to hear and loud speakers are less overwhelming.

This repository contains **VolEq Community**, the open-source edition. It is macOS-first, with platform-neutral core and DSP packages designed for future platform adapters.

> [!IMPORTANT]
> VolEq is early-stage software. The package builds and its DSP tests pass, but it has not yet completed real-world validation across meeting apps, output devices, Bluetooth transitions, latency, and long-running sessions.

## Community edition

The Community app intentionally has a small surface:

- turn voice leveling on or off;
- attach to one currently active application or the device-wide output mix;
- turn speech-aware quiet-gain protection on or off while stopped;
- automatically apply mild noise suppression with speech-aware leveling;
- use fixed, safe speech-leveling and mild-noise-suppression presets.

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

On macOS 14.2+, VolEq uses Core Audio process taps to capture an application's outgoing audio, applies linked-stereo speech leveling, and sends the result to the current default output device. One offline RNNoise state per channel supplies voice activity and aligned denoised audio. Quiet speech can be raised, while static and other non-speech are never raised. During authorized speech with measurable background noise, VolEq automatically blends in at most 50% of the RNNoise output; clean speech, music, and non-speech remain dry. Loud content still receives downward protection regardless of classification. The original selected audio is muted only while VolEq is actively replacing it. Device-wide mode excludes VolEq itself to avoid a feedback loop.

Mild noise suppression is part of speech-aware leveling and runs automatically
whenever speech awareness is on. Turning speech awareness off skips model and
analyzer construction entirely and uses the base lookahead leveler.

Speech analysis uses the bundled model and performs no network requests. VolEq
does not record, persist, upload, or add telemetry to captured audio. See the
[privacy notes](docs/PRIVACY.md).

VolEq measures the aggregate device's input and output cadence against Core Audio's host timestamps, including any drift compensation Core Audio already applies to a Bluetooth tap. When those measurements show that Core Audio has synchronized the route, VolEq bypasses duplicate conversion even if the stream labels still advertise different nominal rates. When they confirm that conversion remains necessary, VolEq converts the processed stream through Audio Converter Services with fixed-capacity real-time input and output FIFOs, so the device receives complete periods after a short pre-roll. It observes default-device, format, sample-rate, and device-availability changes and safely rebuilds the private audio path after a headset or output-route transition.

No virtual audio driver or permanent system-wide output-device change is required.

## Current limitations

- Output changes trigger an automatic reconnect and can produce a brief silence while Core Audio settles the new route.
- Only processes currently producing audio appear in the application selector.
- The current path supports mono or stereo 32-bit floating-point PCM and converts differing capture/output sample rates. Multichannel layouts fail safely before processing starts.
- The optimized mild-suppression build was physically accepted on 2026-08-02 across MacBook speakers, Sennheiser HDB 630, and Apple AirPods Pro 2. The owner covered clean and noisy speech, quiet/loud transitions, microphone bumps, instrumental music, stereo image, an A/B suppression comparison during development, clicks/dropouts, and route restoration. Deterministic tests cover 48↔44.1 kHz and 48→16 kHz paths, but broader headset compatibility, meeting apps, the documented soak, and long-running stability still need structured validation.
- The current mixed-stream processor levels the combined incoming audio. It cannot identify individual meeting participants or keep a separate profile for each speaker.
- Singing can be classified as speech and may therefore receive quiet-speech leveling and mild suppression.
- Speech-aware leveling uses 30 ms total DSP latency at 48 kHz so the pinned RNNoise build's two-block wet reconstruction is aligned correctly for mild suppression. Measured Speex resampler delay raises that total to 33.0 ms at 16 kHz and about 31.13 ms at 44.1 kHz. The leveler's accepted 20 ms loud-onset lookahead remains intact inside that timeline. Turning speech awareness off uses the base leveler's 20 ms timeline.
- The required 48 kHz stereo release benchmark now records 4.33%–4.37% of one core across five post-review runs on the development Mac, passing the unchanged 5% target. Owner listening of the optimized build has passed; the documented soak remains pending and automated CPU evidence does not replace it.

## Repository map

```text
apps/macos/community/     Community macOS app and bundle resources
packages/core/swift/      Platform-neutral product settings and types
packages/dsp/swift/       Platform-neutral speech-leveling DSP
packages/speech/swift/    Offline speech-analysis API and RNNoise adapter
platforms/macos/          Core Audio capture and output adapter
third_party/              Pinned RNNoise and SpeexDSP source subsets
scripts/                  Developer build helpers
docs/                     Architecture, editions, licensing, and roadmap
```

Read [ARCHITECTURE.md](docs/ARCHITECTURE.md) before changing package boundaries.
Dependency revisions, licenses, model checksums, and the manual reproduction
workflow are recorded in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

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
