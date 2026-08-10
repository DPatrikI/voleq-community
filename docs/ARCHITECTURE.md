# Architecture

VolEq uses explicit package boundaries so the audio algorithm can evolve independently from operating-system capture APIs and product UI.

```text
VolEqCommunityMac
    |           |
    |           +-----> GitHub Releases API (manual or consented checks only)
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

`DynamicsProcessor` remains the public orchestration seam. Its internal runtime
state is separated by domain: `DynamicsRuntimeParameters` owns immutable
settings snapshots and normalized coefficients; `DynamicsGainDetector` owns
envelope, gain, and future-peak decisions; `DynamicsLookaheadBuffer` owns the
preallocated `DelayedDynamicsFrame` ring, including delayed samples, caps,
eligibility, suppression metadata, and source tags; `SpeechDynamicsCoordinator`
owns block assembly, authorization, denoised backfill, and suppression targets;
and `DynamicsSuppressionMixer` owns the dry/wet suppression envelope. The
orchestrator still controls call ordering, settings publication, reset, and
failure latching, so every component is prepared before callback processing and
reset returns the complete timeline to its initial state.

### `VolEqSpeech`

The portable, injectable speech-processing API and offline RNNoise
implementation. Stereo routes prepare one independent RNNoise state per channel
while sharing the immutable bundled model. The processor consumes source-rate
frames, converts only its RNNoise stream to and from 48 kHz when necessary, and
reports normalized speech probability, source power, source-frame coverage,
estimated SNR, decision latency, and denoised coverage. The highest channel
probability and that same channel's source power form one linked decision. It
uses `CRNNoise` and the minimal `CSpeexResampler` target.

`RNNoiseStereoProcessor` remains the public lifecycle and processing
orchestrator. `RNNoiseInferenceEngine` owns independent L/R states, paired
inference, and the rotating analysis/denoised buffers. `RNNoiseResampler` owns
input/output converters, measured latency, scratch storage, and reset.
`RNNoiseTaggedStereoHistory` keeps dry samples with source-frame tags;
`RNNoiseDecisionHistory` keeps probabilities, power, and SNR metadata; and
`RNNoiseWetOutputFIFO` keeps converted wet frames with source tags. These
components retain the two-block reconstruction, exact source alignment,
independent channel inference, failure latching, and zero steady-state
callback allocations. Their internal boundaries are implementation details;
the public processor API and latency policy do not change.

The validated route matrix remains 16, 44.1, and 48 kHz. Fixed-block speech
analysis accepts only finite, whole-number source rates in the 8–192 kHz safe
range for which 10 ms contains a whole number of frames (integer rates
divisible by 100). It rejects 22,050 Hz and other fractional-block rates on the
control thread before any processing starts. The macOS adapter preflights the
output rate before creating its muting tap, and tears down any later-created
tap or aggregate resources if the callback rate fails the same rule. The
original audio path remains intact. Alternating fractional-cadence support is
not part of v0.1.0.

On Apple Silicon, the internal RNNoise adapter evaluates the two states through
a paired float kernel covering sparse GRU and dense/conv layers. It shares
immutable model-weight loads only and interleaves independent output rows while
retaining each output's accepted accumulation order; both
channels keep independent feature extraction, recurrent state, probability,
gain, synthesis, and history. The direct 48 kHz path prepares aligned pending
blocks without a redundant FIFO round trip, while converted paths retain their
bounded FIFO. O(1) analysis-history rotation and callback-owned preallocated
buffers remove redundant traversal and Swift copy-on-write bookkeeping without
changing public APIs, source tags, converted FIFO bounds, or failure behavior.

### `VolEqMacAudio`

The macOS adapter. It owns Core Audio process discovery, process taps, aggregate-device lifecycle, audio-buffer adaptation, and output-device interaction. Apple-specific identifiers stay here.

`AudioCaptureController` is a stable `ObservableObject` façade. It publishes the
app-facing selection and settings plus one atomic `AudioCaptureStateSnapshot`.
The existing runtime, running, access, and status names remain read-only
compatibility publishers mirrored from that snapshot; app surfaces consume only
the atomic snapshot, while downstream clients retain their original projected
publishers and exhaustive runtime-state source compatibility. Phase-derived
primary-action readiness is included in the same publication, so an asynchronous stopping
phase cannot render an enabled Start action that lifecycle ownership must reject.
It forwards commands but
owns no Core Audio handles, route listeners,
clocks, watchdogs, or asynchronous lifecycle work.

`AudioCaptureLifecycleCoordinator` is the main-actor policy boundary. One
`CaptureLifecyclePhase` distinguishes stopped, explanation-declined, ready,
explaining, preparing, active, stopping, suspending/suspended, recovering,
recovery-failed, route-monitoring-failed, ordinary-failed, and cleanup-failed
states. Process-discovery and pipeline failures are distinct phases, so Refresh
cannot erase an unrelated failure. The app's
authoritative `captureState` is published atomically from one lifecycle
snapshot; `isRunning`, runtime state, and access state are derived from the
phase, while status is the phase's presentation detail. The legacy projected
publishers (`$isRunning`, `$runtimeState`, `$systemAudioAccessState`, and
`$status`) remain source-compatible sequential mirrors of that snapshot; app
surfaces and accessibility do not consume them as a transaction.
One serialized transition task and a generation token ensure that sleep, wake,
output-route, callback-stall, Stop/Cancel/Quit, and retry events cannot create
competing graphs or accept stale results.
Live leveling settings remain phase-owned configuration rather than operation
identity. Asynchronous results match the stable mode, speech path, and capture
target, then carry the latest phase settings forward; a pipeline finishing
construction receives those current settings before callback Start.

`CaptureLifecycleStateMachine` is the sole phase-and-snapshot mutator. It
applies the pure `CaptureLifecycleReducer` before dispatching commands and
before accepting explanation, pipeline, teardown, recovery-failure, or
termination results. Accepted asynchronous events return their next phase and
effect; stale or phase-incompatible completions publish nothing. Direct
state-machine tests cover valid completion paths and illegal stale events.
`AudioCaptureProcessSession` owns the current process
list, selected identity, and explicit-reselection requirement.
`AudioProcessRefreshCoordinator` owns refresh cancellation and coalescing: one
enumeration may be in flight and only the newest pending request survives. It
cannot publish selection or lifecycle results after either its request or the
owning lifecycle generation becomes stale.
The lifecycle coordinator owns the one first-use explanation decision and
fresh PID-plus-bundle resolution after that explanation. `AudioCaptureRuntime` owns the active pipeline
interface, initial callback gate, watchdog, diagnostics monitor, and retained
pipeline executors. Graph construction and teardown serialize on the lifecycle
executor, while callback Start runs separately so Stop, sleep, or termination
can take ownership even if Core Audio blocks Start. The runtime adopts the
constructed pipeline before Start and retains both in-flight work and the
resulting pipeline until its typed teardown report returns.
`CoreAudioCapturePreflight`
runs on a separate serial executor, so route and format queries cannot block
Stop, sleep, termination, or UI delivery. Failure-to-phase/status mapping is a separate pure presentation
boundary. These components leave the coordinator responsible for serialized
lifecycle policy rather than resource implementation or copy construction.

`AudioCaptureDependencies` composes typed process-catalog, preflight, pipeline,
route-monitor, route-stability, callback-health, clock, and scheduling
contracts. `.live` is the only production composition;
tests provide small fakes for the boundary they exercise. The façade contains
no debug hooks, simulated resources, controller-capturing closures, or test
recorders.

The active muting and processing graph is owned only by
`CoreAudioCapturePipeline`. It stages active-output listeners, the
`.mutedWhenTapped` process tap, private aggregate, I/O proc, processor, and
callback heartbeat. `start()` only starts the prepared callback. Idempotent
`stop()` attempts listener removal independently, then I/O stop and destruction,
aggregate destruction, and tap destruction in dependency order, returning an
`AudioCaptureTeardownReport` for every unresolved step. Failed ancillary
listener removal cannot skip muting-graph teardown. A failed I/O-proc destroy
retains its device, aggregate, and tap and blocks downstream destruction until
a retry succeeds; an aggregate failure similarly retains the tap. Unresolved
ownership blocks replacement. Deinitialization schedules the same best-effort
path off the main actor and deliberately retains unresolved callback ownership.
The I/O callback owner explicitly distinguishes prepared, Start-pending,
running, and stopped states. Teardown may issue a preemptive Stop to unblock a
pending Start, but records stopped only after the Start result and an
authoritative post-completion Stop; a Start that outlives the bounded shutdown
wait automatically finishes the requested teardown before releasing ownership.
Core Audio property helpers cap array allocations at one MiB and treat the
second property read's returned byte count as authoritative. Shrinking process
lists are read only through the returned elements; oversized first reads,
growth, and partial-element sizes fail safely instead of exposing uninitialized
storage. One canonical capture-format validator rejects non-finite or unsupported
sample rates, non-native or unpacked Float32 PCM, and inconsistent packet/frame
strides at the preflight, route-observation, and pipeline boundaries.

`CoreAudioProcessCatalog` owns enumeration, while `CoreAudioCapturePreflight`
owns route-format validation and preparation of an already-resolved target.
Catalog property reads and route observations run on dedicated serial executors,
then publish their typed results on the main actor. Refresh requests retain at
most one in-flight enumeration and one latest pending request; cancelled queued
reads check their lease before touching HAL so refresh storms cannot starve the
fresh identity resolution required by Start or recovery.
`ApplicationCaptureTargetResolver` owns restoration identity rules.
`AudioOutputRouteMonitor` owns default-output notifications, while
`AudioOutputRouteStabilityGate` owns the bounded settling algorithm and compares
notifications with the latest prepared or active route observation to absorb
unchanged duplicates during explanation, preparation, and
after recovery. Listener installation and removal run on the monitor's retained
serial executor. Notification comparison retains one in-flight observation and
one pending recheck, and every stability observation is raced against the
remaining absolute deadline, so a slow or hung HAL read cannot extend the
ten-second recovery window.
`AudioCallbackHealthMonitor` owns initial callback progress and the single
stall notification. These boundaries keep lifecycle policy independent of raw
Core Audio construction and timing machinery.

Default-output monitoring is a startup prerequisite. An internal installing
phase keeps commands non-ready while the serial executor registers the listener.
A registration failure has its own non-startable lifecycle phase; Start may
retry installation, but no graph is created until monitoring is
confirmed. Listener removal
returns a typed report and retains a failed registration so it can be retried
without installing a competing callback.

`prepareForSystemSleep()` snapshots capture mode, processing settings, speech
awareness, and the selected application's Core Audio object, PID, bundle ID,
and display name whenever startup, recovery, or active leveling reflects user
intent. It cancels startup, route, diagnostics, and watchdog work,
then removes active-output listeners and stops/destroys the I/O proc, aggregate,
tap, and processors in the established order. `isRunning` becomes false
immediately in a suspending phase while ownership remains retained until
asynchronous cleanup finishes. Wake during that interval is coalesced and
recovery begins only after cleanup completes; another sleep before completion
cancels that queued wake. A
failed stop or destroy retains the unresolved identifiers, blocks replacement,
and reports a Quit-required failure without claiming restoration. A stopped
session records no wake intent.

`resumeAfterSystemWake()` coalesces duplicate wake and application-activation
delivery. It waits one second, then requires two identical valid default-output
observations 250 ms apart within a 10-second window. After the route stabilizes,
it refreshes the format and process list. Application capture first matches PID
plus bundle ID, then permits one unique exact bundle-ID match for a relaunched
process. The same PID-plus-bundle resolution runs before every ordinary
application preflight, and the production pipeline validates the resolved
identity again immediately before tap construction. Bundleless, missing,
ambiguous, reused, or unexpectedly moved targets fail safely. Missing or
ambiguous targets require explicit selection; the first or an unrelated process
is never substituted. Device-wide capture resolves the current route and VolEq
exclusion afresh.

System Audio Recording startup is intentionally direct. The application shell
first presents the persisted privacy explanation. After Continue, the
coordinator freshly resolves the target, runs non-mutating route/format/model
preflight, and constructs the real processing pipeline. That Core Audio request
is what causes macOS to present its System Audio Recording prompt. The public
SDK has no dedicated authorization-status API, so VolEq does not attempt to
infer permission from signal level, silence, or callback timing. There is no
temporary permission tap, signal threshold, access-check timer, or automatic
permission retry.

Contributor runs use a distinct development bundle identifier and display name.
This keeps an installed Developer-ID release and an ad-hoc source build from
sharing an ambiguous System Settings row. Because an ad-hoc designated
requirement is tied to one exact binary, a rebuilt development app may require a
fresh grant; relaunching the already built app preserves that binary identity.

`isRunning` remains false through explanation, preflight, construction, and
callback startup, and becomes true only after the real pipeline starts and
callback progress is observed. Ordinary Core Audio startup failures begin
complete graph teardown. If Core Audio refuses a stop or destroy operation,
VolEq retains resource ownership, blocks another pipeline, requires Quit, and
does not claim restoration. Production code uses only public Core Audio APIs;
focused tests drive typed protocols and resource owners directly rather than
reaching through the façade.

Wake, output-route, and callback-stall recovery use that same safe-start method;
there is no independent muting rebuild path. Recovery stays non-Active through
route readiness, process restoration, preflight, and pipeline construction. The
replacement graph is reported Active only after `AudioDeviceStart` and observed
callback progress. Stop, Cancel, Quit, or a newer generation clears resume intent
so a late readiness or pipeline result cannot reactivate audio.

Each processing graph owns a preallocated `AudioCallbackHeartbeat` backed by a
lock-free C11-atomic 64-bit counter. The real-time I/O callback performs one
relaxed atomic increment before processing and does no clock conversion, task
creation, allocation, locking, logging, or UI work. The main-actor watchdog
samples the counter every 250 ms only while the graph is Active. Any progress,
including callbacks containing silence, is healthy; two seconds without
progress immediately leaves Active, tears down the muting graph, and schedules
one bounded recovery attempt. Watchdog accounting is disarmed during deliberate
teardown, suspension, and route recovery.

Within the callback pipeline, `AudioIOProcessor` owns the prepared direct and
converted DSP paths and selects exactly one after `AudioCallbackCadenceAnalyzer`
resolves the hardware clocks. `BufferedSampleRateConverter` owns the Core Audio
converter, scratch storage, pre-roll, and complete-period delivery. Its input
and output `StereoFrameRingBuffer` instances own bounded callback-only storage
and drop the oldest frame on overflow so conversion recovers at the live edge.
`AudioIOProcessingDiagnostics` is the immutable control-thread snapshot
published once after route selection. These types do not construct resources,
allocate, block, or log while processing a callback.

### `VolEqCommunityMac`

The open-source macOS application shell. It owns the Community interface,
permission-facing copy, and edition-specific product presentation. A shared
`VolEqControlSurfaceModel` contract supplies the utility window and menu-bar
popover with the same capture targets, settings, runtime state, status, and
commands. `CapturePresentation` is the single value mapping lifecycle state to
title, full and compact actions, status tone, control locking, target summary,
and accessibility text. Both surfaces consume that value; presentation tests
drive a controllable model rather than searching Swift source text.
`AppDelegate` owns native window controllers, Dock activation policy,
Settings presentation, and explicit termination behavior. Changing between
Window and Menu Bar presentation changes only application-shell state; it does
not rebuild or mutate the active audio path.

`SystemAudioAccessPresentationController` owns explanation acceptance
persistence and injectable System Settings navigation. `AppDelegate` presents
the native Continue / Not Now explanation. Both control surfaces always render
the same **No sound?** action. Its native help reiterates that audio is processed
only in memory and is never recorded, saved, uploaded, or sent as telemetry,
then offers direct navigation to System Audio Recording settings without
coupling that shell concern to Core Audio.

An injectable `WorkspaceLifecycleForwarder` sends
`NSWorkspace.willSleepNotification` and `didWakeNotification` to the audio
controller. Wake delivery to the update controller uses a separate subscription
so audio recovery cannot suppress update scheduling. Application activation is
also forwarded; the audio controller ignores it unless a suspended session has
pending resume intent. Both native surfaces therefore derive Paused for System
Sleep, Restoring Leveling, Leveling Did Not Resume, Stop, and Try Again from the
same presentation mapping and announce recovery state changes through macOS
accessibility.

The application shell also owns first-party branding integration. The build
copies a generated `.icns` and a 256-by-256-pixel template raster for the macOS
menu bar. The application icon is supplied by `NSApplication`; at runtime the
template `NSImage` has an intrinsic 18-by-18-point size. Resource filenames are
declared in the application property list and consumed through a typed branding
resource component. `scripts/generate-macos-icon.swift` recreates the files
deterministically from the preserved original VolEq premium icon layers. It
does not generate or reinterpret the logo.

The application target should not contain DSP or raw Core Audio lifecycle
logic.

Update checking is also application-shell-only. `ApplicationVersion` parses
strict three-component installed versions and canonical `vMAJOR.MINOR.PATCH`
release tags with numeric comparison. `GitHubReleaseChecker` uses an injected,
bounded HTTP client to read the latest public full release without
authentication. Its ephemeral URL session rejects redirects, disables
persistent caches, cookies, and credentials, and accepts only the expected
GitHub API response. Release links are exposed only after exact HTTPS host,
credential, and repository-tag path validation.

The main-actor `UpdateController` owns the one-time second-launch consent,
rolling 24-hour automatic-attempt gate, activation/wake and tolerant timer
scheduling, request deduplication, stale-result protection, persistence, and UI
state. Its clock, checker, defaults, workspace opener, and scheduler boundaries
are injectable for deterministic tests. Network parsing runs outside the main
actor and never enters the audio callback. Manual checks bypass the daily gate;
automatic failures update Settings without presenting an alert. Only a
validated GitHub release page may be opened, and VolEq never downloads or
executes update content.

Update persistence is deliberately narrow: consent, enabled state, ordinary
launch count, last automatic-attempt date, last completed-check status, and the
last known available version. The release URL is reconstructed from the strict
version and fixed GitHub origin after relaunch rather than persisted from a
response. Persisted status copy never attributes an older result to the current
installed version, and catching up to a cached release resets that status until
another check completes.

The macOS shell maintains these presentation invariants:

- Window and Menu Bar are mutually exclusive presentations over the same
  application model and audio controller.
- Window presentation uses regular activation policy and Dock presence; Menu
  Bar presentation uses accessory activation policy and keeps Settings and Quit
  reachable from the popover.
- Closing the utility window or dismissing the popover does not stop leveling or
  terminate the application. Reopening the application restores the utility
  window when Window presentation is active.
- Removing the menu-bar item returns the application to Window presentation.
  A failed activation-policy change rolls back to the previously reachable
  presentation.
- Explicit Quit stops active leveling before process termination.
- Update checks never start, stop, rebuild, or otherwise mutate the audio
  controller; presentation changes and update activity remain independent of
  the active realtime path.

## Dependency rules

- Lower-level packages never import an app target.
- Core, DSP, and Speech must not depend on macOS UI or Core Audio APIs.
- Platform adapters may depend on Core, DSP, and Speech.
- Product apps depend on platform adapters and may compose shared packages.
- VolEq Pro-only files must live in the separate private repository; public
  MPL-covered files are consumed as dependencies rather than copied or forked.
- New internal DSP and speech types remain package-private implementation
  boundaries; no public API or `Package.swift` interface is added for them.

## Real-time audio rules

- Do not allocate memory, wait on a contended lock, log, or call UI code in the audio callback.
- The processing callback increments only its preallocated lock-free C11-atomic
  heartbeat before feeding prepared processors. Time measurement, stall
  decisions, recovery tasks, status, and accessibility stay on the control
  thread; potentially blocking HAL teardown runs on the retained serial cleanup
  executor.
- UI settings are published as snapshots. The callback uses its previous snapshot if an update lock is busy.
- The leveler allocates its linked-stereo lookahead storage during construction. Its default 20 ms delay lets the detector lower gain before a loud onset is emitted; the delay, detector, and gain history start empty whenever the audio route is rebuilt. The first lookahead period is therefore silence by design. A future peak may lower the gain envelope immediately but may never raise it, and its maximum-gain cap travels with the delayed frame so release smoothing cannot outrun an isolated transient. The delayed frame still passes through the final safety limiter.
- RNNoise model loading and checksum verification finish before the process tap
  is created. Two-channel state creation, resampler setup, and buffer allocation
  finish before `AudioDeviceStart`, which is when the prepared process tap can
  begin replacing original audio. Components that allocate lazily are primed
  before that point, and route resets reconstruct their resamplers on the
  control thread. The callback feeds prepared state only. Speech
  eligibility is stored beside delayed audio and transient caps; a result can
  backfill only the source frames it covers, so an opening syllable is preserved
  without granting upward gain to earlier unrelated sound.
- Mild suppression is part of speech-aware leveling. When speech awareness is
  enabled before the route starts, the route prepares two RNNoise states per
  processing path and uses the aligned wet timeline below. Disabling speech
  awareness skips all model and analyzer construction and uses the base leveler.
- RNNoise probability describes the current 10 ms input block, while wet audio
  follows a separate overlap-add timeline. Absolute source-frame tags and
  fixed-capacity dry/wet storage validate every mapping before backfilling the
  lookahead ring. The pinned RNNoise main reconstruction maps principally to
  input block `k - 2`, so the first two wet blocks are warm-up and remain dry.
  The owner accepted the resulting 30 ms 48 kHz timeline. Quality-3 Speex
  resampling adds only its measured round-trip delay: 24 + 24 frames at 16 kHz
  and 24 + 26 frames at 44.1 kHz. Total DSP delay is 528 frames (33.0 ms), 1,373
  frames (about 31.13 ms), and 1,440 frames (30.0 ms) at 16, 44.1, and 48 kHz.
  The existing detector still has at least its accepted 20 ms to protect loud
  onsets.
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
  uses the base leveler. The setting is fixed while running, so changing modes
  never constructs or destroys processing state in the callback.
- Mild suppression has a separate activity gate so leveling's 200 ms hold and
  150 ms eligibility fade do not lengthen its timing. The linked wet target is
  50% when estimated SNR is at or below 18 dB, follows a smoothstep taper to
  zero by 24 dB, and is zero for invalid or negligible removed power. The
  per-sample linked coefficient takes 30 ms for dry-to-50% and 100 ms for
  50%-to-dry. Dry detection, transient caps, compression, and limiting remain
  unchanged; aligned wet/dry blending happens before the linked gain. The
  slower platform authority must authorize speech, and a music result targets
  dry immediately. Non-speech and music are fully dry after the release.
- On macOS, RNNoise voice activity is combined with the operating system's offline
  sound classifier before upward gain or suppression is permitted. Audio reaches that slower
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
  The first RNNoise warm-up output remains dry. Non-finite input or metadata,
  corrupt wet samples, impossible source mappings, FIFO overflow, or resampler
  failure latches the processor in a silent failed state and publishes
  one preallocated failure signal without blocking. A control-thread monitor then
  attempts complete replacement-path teardown. Original audio is considered
  restored only after that teardown completes; unresolved Core Audio ownership
  remains retained, blocks restart, and requires Quit.
- The processor measures the aggregate callback's input/output frame cadence against Core Audio host timestamps, not only the tap's advertised rates or a single pair of buffer sizes. A shared effective clock indicates that tap drift compensation already synchronized the Bluetooth route and duplicate conversion must be bypassed; distinct input/output clocks use Audio Converter Services with preallocated input and output FIFOs. The output FIFO pre-rolls briefly and writes only complete device periods. A full FIFO drops its oldest frame to recover at the live edge instead of accumulating latency, while missing or inconclusive timing fails safely and sustained output underruns never emit repeated partial periods.
- Always tear down the I/O callback before destroying its aggregate device or process tap.
- Default-output, device-alive, sample-rate, and stream-format listeners rebuild the complete audio path after route or Bluetooth profile changes.
- Device-wide capture must exclude VolEq's own process to prevent feedback.
- Unsupported formats must fail safely instead of emitting corrupt audio.

## Future platforms

A new operating system should add a sibling under `platforms/<platform>` and a product under `apps/<platform>`. Shared algorithms belong in `packages`, not in a platform folder. This layout supports future platforms; it does not claim they are currently implemented.

Frontend ownership and the conditions for reconsidering a shared UI toolkit are
defined in [ADR 0001: Thin Native Frontends](decisions/0001-thin-native-frontends.md).
