# VolEq — Volume Equilibrium

VolEq automatically levels voice volume so quiet speakers are easier to hear
and loud speakers are less overwhelming.

<p align="center">
  <img src="docs/assets/voleq-community-window.png" width="560" alt="VolEq Community window showing stopped device-wide capture with speech-aware leveling enabled">
</p>

## Download and install

Download the Apple Silicon DMG from
[GitHub Releases](https://github.com/DPatrikI/voleq-community/releases), open it,
and drag **VolEq Community** to **Applications**. Launch the installed app and
start audio in the application you want to level. On the first Start attempt,
VolEq explains why access is needed before macOS asks for System Audio Recording
permission. Keep that audio playing while VolEq verifies access. The original
audio remains unchanged until access is verified and the processing path is
successfully active.

> **Known v0.1.0 issue:** the published 0.1.0 build can incorrectly enter a
> muting capture path after System Audio Recording access is denied. Stop or
> quit VolEq to restore the original path. The Unreleased 0.1.1 fix described
> in this source tree is pending signed-bundle owner validation and has not yet
> been released.

VolEq Community 0.1.0 requires an Apple Silicon Mac running macOS 14.2 or newer.
See the [tested compatibility matrix](docs/COMPATIBILITY.md) for the exact Macs,
meeting apps, wired outputs, and Bluetooth devices covered before release.

To remove VolEq, first stop leveling and quit the app, then move
`VolEq Community.app` from Applications to the Trash. Its System Audio Recording
permission can be removed separately in System Settings.

## What it does

- Captures one active application or the complete device-wide output mix.
- Raises quiet speech and controls loud speech with linked-stereo leveling and
  lookahead peak protection.
- Prevents music and unrelated sounds from receiving quiet-speech gain.
- Applies automatic mild noise suppression when speech and background noise are
  both detected.
- Supports built-in, wired, and Bluetooth outputs, including microphone-active
  headset call modes.
- Processes audio locally and offline with no account, audio recording,
  telemetry, or model download. Manual or explicitly enabled daily update
  checks contact GitHub without sending audio or usage data.
- Offers native window and menu-bar presentations.

The default speech-aware path introduces approximately **30 ms of DSP latency at
48 kHz**. The measured total is about 31.13 ms at 44.1 kHz and 33 ms at 16 kHz;
device and route buffering can add more. With speech awareness disabled, the
base leveler uses 20 ms lookahead.

## Current limitations

- VolEq levels the combined captured mix; it cannot control each meeting
  participant independently.
- Only mono or stereo 32-bit floating-point PCM is supported. Multichannel
  layouts fail safely before processing begins.
- Speech-aware processing is validated at 16, 44.1, and 48 kHz. Fractional
  10 ms rates such as 22.05 kHz are rejected before VolEq replaces the original
  audio.
- An output change stops processing, restores the original path, and repeats
  the unmuted access check before rebuilding the processing route.
- Only applications currently producing audio appear in application capture.
- Singing may be classified as speech and receive leveling or mild suppression.
- The official 0.1.0 binary is arm64-only; Intel Macs are not supported.

## Build from source

Building requires Xcode or Apple Command Line Tools with Swift 5.10 or newer.

```sh
./dev doctor
./dev test
./dev build macos
./dev run macos
```

The contributor build is assembled and ad-hoc signed at
`dist/VolEq Community.app`. Official Developer ID signing and notarization use
the maintainer-only `./dev package macos` workflow documented in
[RELEASING.md](docs/RELEASING.md).

## How it works

On macOS, VolEq uses Core Audio process taps to capture outgoing audio, process
it, and send it to the current output device. Bundled RNNoise states and Apple's
offline SoundAnalysis framework authorize quiet-speech gain and mild
suppression. Loud content retains downward peak protection regardless of its
classification. VolEq mutes the selected original stream only while its
replacement path is active. Before every fresh start and route rebuild, an
unmuted input-only probe verifies two callbacks containing real finite audio;
the probe is destroyed before the muting replacement path is created. A denied,
cancelled, silent, timed-out, malformed, or ordinary startup failure leaves
VolEq stopped and the original audio unchanged when cleanup completes. If Core
Audio refuses cleanup, VolEq retains the affected resources, requires Quit, and
does not claim restoration.

No virtual audio driver, permanent output-device change, online audio service,
or model download is required. The optional first-party update checker reads the
latest published release from GitHub and never downloads or installs an update.
See [ARCHITECTURE.md](docs/ARCHITECTURE.md) for the audio pipeline and
[PRIVACY.md](PRIVACY.md) for the concise privacy statement.

## System Audio Recording troubleshooting

If VolEq says audio access could not be verified:

1. Keep the selected application or device-wide mix audibly playing. Silence is
   indistinguishable from unavailable access through the public Core Audio API.
2. Choose **Open System Settings…** and confirm VolEq under **Privacy &
   Security → Screen & System Audio Recording**.
3. If macOS asks you to quit and reopen VolEq after changing access, do that
   before choosing **Check Again**.
4. Confirm the correct application is still producing audio and that the output
   device is available, then choose **Check Again**.

VolEq does not claim that a timed-out check means permission was denied. In all
unverified states, processing remains stopped and the original audio should
remain audible. Settings and update checking remain available without audio
access.

## Community edition

This repository contains the useful, buildable open-source edition. VolEq
Premium is planned as a separate application for advanced controls, profiles,
automation, automatic switching, and commercial support—not a better version of
the core processor. See [EDITIONS.md](docs/EDITIONS.md).

## Project documentation

- [Compatibility](docs/COMPATIBILITY.md)
- [Validation evidence](docs/VALIDATION.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Roadmap](docs/ROADMAP.md)
- [Licensing model](docs/LICENSING.md)
- [Third-party notices](THIRD_PARTY_NOTICES.md)
- [Release procedure](docs/RELEASING.md)

## Contributing

Bug reports and focused pull requests are welcome. Read
[CONTRIBUTING.md](CONTRIBUTING.md) and include the required Developer Certificate
of Origin sign-off.

## Maintainer

Created and maintained by Patrik István Dóczy.

- [LinkedIn](https://www.linkedin.com/in/patrik-istv%C3%A1n-d%C3%B3czy/)
- [X — development updates and future projects](https://x.com/hapci410)

## License

Source and documentation are licensed under the
[Mozilla Public License 2.0](LICENSE), unless a file states otherwise. The
**VolEq** name, logo, application icon, and official visual identity are not
licensed under MPL-2.0; see [TRADEMARKS.md](TRADEMARKS.md).
