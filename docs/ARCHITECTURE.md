# Architecture

VolEq uses explicit package boundaries so the audio algorithm can evolve independently from operating-system capture APIs and product UI.

```text
VolEqCommunityMac
        |
        v
 VolEqMacAudio ------> VolEqDSP ------> VolEqCore
        |                 |
        |                 v
        +----------> VolEqSpeech ------> CRNNoise
                          |
                          +-----------> CSpeexResampler
```

## Package responsibilities

### `VolEqCore`

Platform-neutral settings and product-domain types. It must not import SwiftUI, AppKit, Core Audio, or platform-specific process identifiers.

### `VolEqDSP`

The speech-leveling signal-processing implementation. It operates on numeric audio frames and must not know where audio came from or where it will be sent. New platform adapters should reuse this package instead of copying the algorithm.

### `VolEqSpeech`

The portable, injectable speech-analysis API and offline RNNoise implementation.
It consumes fixed 10 ms mono source blocks, resamples only its analysis stream
when needed, and reports normalized speech probability, source power, source
frame coverage, and analysis latency. It uses `CRNNoise` and the minimal
`CSpeexResampler` target; denoised RNNoise samples are discarded on this branch.

### `VolEqMacAudio`

The macOS adapter. It owns Core Audio process discovery, process taps, aggregate-device lifecycle, audio-buffer adaptation, and output-device interaction. Apple-specific identifiers stay here.

### `VolEqCommunityMac`

The open-source macOS application shell. It owns the Community interface, permission-facing copy, and edition-specific product presentation. It should not contain DSP or raw Core Audio lifecycle logic.

## Dependency rules

- Lower-level packages never import an app target.
- Core, DSP, and Speech must not depend on macOS UI or Core Audio APIs.
- Platform adapters may depend on Core, DSP, and Speech.
- Product apps depend on platform adapters and may compose shared packages.
- Premium-only files must live in the separate private repository; public MPL-covered files are consumed as dependencies rather than copied or forked.

## Real-time audio rules

- Do not allocate memory, wait on a contended lock, log, or call UI code in the audio callback.
- UI settings are published as snapshots. The callback uses its previous snapshot if an update lock is busy.
- The leveler allocates its linked-stereo lookahead storage during construction. Its default 20 ms delay lets the detector lower gain before a loud onset is emitted; the delay, detector, and gain history start empty whenever the audio route is rebuilt. The first lookahead period is therefore silence by design. A future peak may lower the gain envelope immediately but may never raise it, and its maximum-gain cap travels with the delayed frame so release smoothing cannot outrun an isolated transient. The delayed frame still passes through the final safety limiter.
- RNNoise model loading and checksum verification finish before the process tap
  is created. Analyzer-state creation, resampler setup, and buffer allocation
  finish before `AudioDeviceStart`, which is when the prepared process tap can
  begin replacing original audio. The callback feeds prepared state only. Speech
  eligibility is stored beside delayed audio and transient caps; a result can
  backfill only the source frames it covers, so an opening syllable is preserved
  without granting upward gain to earlier unrelated sound.
- Non-quiet speech opens at probability 0.65. Quiet audio requires probability
  0.90 for two consecutive 10 ms blocks; the accepted 20 ms lookahead lets the
  confirmed decision cover both blocks before they become audible. Once quiet
  speech is open, it remains open above 0.35 and may extend below the normal
  -55 dB floor down to -80 dB, but still requires 6 dB of clearance above the
  learned background. Both paths hold for 200 ms, then fade upward eligibility
  over 150 ms. The background floor learns only at probability 0.20 or lower
  with a two-second time constant. Classification never disables downward
  compression, lookahead protection, or limiting.
- Speech decisions never snap the output gain at a 10 ms analysis boundary.
  Upward gain rises with a 30 ms per-sample slew. Its removal follows the gate's
  existing 150 ms eligibility fade, while zero eligibility enforces unity
  immediately. Gain below unity remains immediate so loud onsets retain
  lookahead protection. Disabling
  speech-aware leveling while stopped skips model and analyzer construction and
  uses the base leveler.
- On macOS, RNNoise voice activity is checked by the operating system's offline
  sound classifier before upward gain is permitted. Audio reaches that slower
  classifier through a preallocated single-producer/single-consumer ring; only
  an atomic permission bit crosses back into the real-time callback. The system
  classifier uses 500 ms windows with 50% overlap. Two consecutive speech
  results are required, so the beginning of a newly detected speaker remains dry
  for roughly 750 ms rather than increasing the audio delay. Speech must score at
  least 0.22 and at least 55% of the strongest music or instrument score. Music
  closes permission immediately, uncertain results receive a four-result hold,
  and a 500 ms input gap resets permission and marks a discontinuity in the
  system analyzer timeline so pre-gap speech cannot influence newly starting
  content. This platform adapter never changes downward compression, lookahead
  protection, or limiting.
- macOS prepares separate system content analyzers for the direct and converted
  paths before audio starts. The direct analyzer uses the output device's
  effective rate, while the converted analyzer uses the captured input rate.
  Cadence resolution feeds only the selected analyzer, preventing synchronized
  aggregate and Bluetooth routes from labeling output-clock samples with a
  stale nominal input rate.
- Model construction, latency inspection, reset, and settings mutation are
  control-thread operations. Only prepared sample processing is real-time safe.
  Non-finite analysis latches the processor in a silent failed state and publishes
  one preallocated failure signal without blocking. A control-thread monitor then
  tears down the replacement path so Core Audio restores the original audio.
- The processor measures the aggregate callback's input/output frame cadence against Core Audio host timestamps, not only the tap's advertised rates or a single pair of buffer sizes. A shared effective clock indicates that tap drift compensation already synchronized the Bluetooth route and duplicate conversion must be bypassed; distinct input/output clocks use Audio Converter Services with preallocated input and output FIFOs. The output FIFO pre-rolls briefly and writes only complete device periods. A full FIFO drops its oldest frame to recover at the live edge instead of accumulating latency, while missing or inconclusive timing fails safely and sustained output underruns never emit repeated partial periods.
- Always tear down the I/O callback before destroying its aggregate device or process tap.
- Default-output, device-alive, sample-rate, and stream-format listeners rebuild the complete audio path after route or Bluetooth profile changes.
- Device-wide capture must exclude VolEq's own process to prevent feedback.
- Unsupported formats must fail safely instead of emitting corrupt audio.

## Future platforms

A new operating system should add a sibling under `platforms/<platform>` and a product under `apps/<platform>`. Shared algorithms belong in `packages`, not in a platform folder. This layout supports future platforms; it does not claim they are currently implemented.
