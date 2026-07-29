# Architecture

VolEq uses explicit package boundaries so the audio algorithm can evolve independently from operating-system capture APIs and product UI.

```text
VolEqCommunityMac
        |
        v
 VolEqMacAudio ------> VolEqDSP ------> VolEqCore
        |                                  ^
        +----------------------------------+
```

## Package responsibilities

### `VolEqCore`

Platform-neutral settings and product-domain types. It must not import SwiftUI, AppKit, Core Audio, or platform-specific process identifiers.

### `VolEqDSP`

The speech-leveling signal-processing implementation. It operates on numeric audio frames and must not know where audio came from or where it will be sent. New platform adapters should reuse this package instead of copying the algorithm.

### `VolEqMacAudio`

The macOS adapter. It owns Core Audio process discovery, process taps, aggregate-device lifecycle, audio-buffer adaptation, and output-device interaction. Apple-specific identifiers stay here.

### `VolEqCommunityMac`

The open-source macOS application shell. It owns the Community interface, permission-facing copy, and edition-specific product presentation. It should not contain DSP or raw Core Audio lifecycle logic.

## Dependency rules

- Lower-level packages never import an app target.
- Core and DSP must not depend on macOS UI or Core Audio APIs.
- Platform adapters may depend on Core and DSP.
- Product apps depend on platform adapters and may compose shared packages.
- Premium-only files must live in the separate private repository; public MPL-covered files are consumed as dependencies rather than copied or forked.

## Real-time audio rules

- Do not allocate memory, wait on a contended lock, log, or call UI code in the audio callback.
- UI settings are published as snapshots. The callback uses its previous snapshot if an update lock is busy.
- The leveler allocates its linked-stereo lookahead storage during construction. Its default 10 ms delay lets the detector lower gain before a loud onset is emitted; the delay, detector, and gain history start empty whenever the audio route is rebuilt. The first lookahead period is therefore silence by design. A future peak may lower the gain envelope immediately but may never raise it. The delayed frame still passes through the final safety limiter.
- The processor measures the aggregate callback's input/output frame cadence against Core Audio host timestamps, not only the tap's advertised rates or a single pair of buffer sizes. A shared effective clock indicates that tap drift compensation already synchronized the Bluetooth route and duplicate conversion must be bypassed; distinct input/output clocks use Audio Converter Services with preallocated input and output FIFOs. The output FIFO pre-rolls briefly and writes only complete device periods. A full FIFO drops its oldest frame to recover at the live edge instead of accumulating latency, while missing or inconclusive timing fails safely and sustained output underruns never emit repeated partial periods.
- Always tear down the I/O callback before destroying its aggregate device or process tap.
- Default-output, device-alive, sample-rate, and stream-format listeners rebuild the complete audio path after route or Bluetooth profile changes.
- Device-wide capture must exclude VolEq's own process to prevent feedback.
- Unsupported formats must fail safely instead of emitting corrupt audio.

## Future platforms

A new operating system should add a sibling under `platforms/<platform>` and a product under `apps/<platform>`. Shared algorithms belong in `packages`, not in a platform folder. This layout supports future platforms; it does not claim they are currently implemented.
