# VolEq — Volume Equilibrium

VolEq automatically levels voice volume so quiet speakers are easier to hear
and loud speakers are less overwhelming. It runs locally on your Mac and works
with one audio-producing application or the complete output mix.

<p align="center">
  <img src="docs/assets/voleq-window.png" width="560" alt="VolEq window showing stopped device-wide capture with speech-aware leveling enabled">
</p>

## Platform support

| Platform | Status | Requirements |
| --- | --- | --- |
| macOS | Supported | Apple Silicon, macOS 14.2 or newer |
| Windows | Planned | Not yet available |
| Linux | Planned | Not yet available |

## Download and install

Download the latest Apple Silicon DMG from
[GitHub Releases](https://github.com/DPatrikI/voleq-community/releases), open it,
and drag **VolEq** to **Applications**. Start playback, choose an application or
device-wide capture, select **Start**, and follow the macOS System Audio
Recording prompt.

> Upgrading from 0.1.0? Remove `VolEq Community.app` before installing
> `VolEq.app` so macOS does not retain two copies with the same identity.

## Features

- Captures one active application or the complete device-wide output mix.
- Raises quiet speech and controls loud speech with linked-stereo leveling and
  lookahead peak protection.
- Prevents music and unrelated sounds from receiving quiet-speech gain.
- Applies automatic mild noise suppression when speech and background noise are
  both detected.
- Recovers conservatively across output changes, full system sleep, stalled
  audio callbacks, and independently confirmed stale device-wide capture.
- Offers native window and menu-bar presentations.

## Local audio and update privacy

Captured audio is processed only in memory on your Mac. VolEq has no account,
audio recording, telemetry, model download, or online speech service. Manual
update checks—and optional checks enabled by you at most once every 24 hours
while VolEq is open—contact the VolEq Community repository on GitHub. They send
no audio or usage data, and VolEq never downloads or installs an update. See the
full [privacy statement](PRIVACY.md).

## Compatibility and limitations

VolEq requires an **Apple Silicon Mac running macOS 14.2 or newer**. The default
speech-aware path adds approximately **30 ms of DSP latency at 48 kHz**; device
and route buffering can add more. See the
[compatibility matrix](docs/COMPATIBILITY.md) for exact validation scope.

- VolEq levels the combined captured mix; it cannot control each meeting
  participant independently.
- Only mono or stereo 32-bit floating-point PCM is supported. Multichannel
  layouts fail safely before processing begins.
- Speech-aware processing is validated at 16, 44.1, and 48 kHz. Fractional
  10 ms rates such as 22.05 kHz are rejected before VolEq replaces the original
  audio.
- Output changes and wake can require route reconstruction. If reconstruction
  cannot complete safely, VolEq stops instead of claiming that leveling resumed;
  failed Core Audio cleanup can require Quit.
- Only applications currently producing audio appear in application capture.
- Singing may be classified as speech and receive leveling or mild suppression.

## Build from source

Building requires Xcode or Apple Command Line Tools with Swift 5.10 or newer.

```sh
./dev doctor
./dev test
./dev build macos
./dev run macos
```

`./dev build macos` assembles the release-shaped, ad-hoc-signed artifact at
`dist/VolEq.app`. `./dev run macos` launches a separately identified
`dist/VolEq Dev.app`, so its local System Audio Recording grant cannot be
confused with an installed release. Official Developer ID signing and
notarization use the maintainer-only `./dev package macos` workflow documented
in [RELEASING.md](docs/RELEASING.md).

## Open-source and Pro editions

This Community repository builds the complete open-source application named
**VolEq**. **VolEq Pro** is planned as a separate application for advanced
controls, profiles, automation, automatic switching, and commercial support—not
a better version of the core processor. See [EDITIONS.md](docs/EDITIONS.md).

## Documentation and community

- [Compatibility](docs/COMPATIBILITY.md)
- [Validation evidence](docs/VALIDATION.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Roadmap](docs/ROADMAP.md)
- [Licensing model](docs/LICENSING.md)
- [Third-party notices](THIRD_PARTY_NOTICES.md)
- [Release procedure](docs/RELEASING.md)
- [Build and contribution guide](CONTRIBUTING.md)
- [LinkedIn](https://www.linkedin.com/in/patrik-istv%C3%A1n-d%C3%B3czy/)
- [X — development updates and future projects](https://x.com/hapci410)

## License

Source and documentation are licensed under the
[Mozilla Public License 2.0](LICENSE), unless a file states otherwise. The
**VolEq** name, logo, application icon, and official visual identity are not
licensed under MPL-2.0; see [TRADEMARKS.md](TRADEMARKS.md).
