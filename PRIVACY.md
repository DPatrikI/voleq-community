# Privacy

VolEq Community processes captured audio locally in memory. Captured audio is never saved, uploaded, or used for telemetry. When speech-aware leveling is enabled, bundled RNNoise states analyze and mildly denoise speech. Turning speech awareness off skips RNNoise and speech analysis entirely. Apple's offline SoundAnalysis framework supplies the slower speech-versus-music decision. The application does not create user accounts or include analytics. Update checks never include captured audio or usage telemetry.

macOS controls access through System Audio Recording permission. Before a muting processing path can exist, VolEq uses a temporary unmuted, input-only Core Audio probe for the selected application or device-wide mix. The probe never replays samples or changes the original output and keeps samples only in memory. Silence, cancellation, timeout, malformed input, permission failure, or an ordinary Core Audio startup failure leaves VolEq stopped with the original audio unchanged when cleanup completes. If Core Audio refuses to stop or destroy a resource, VolEq retains ownership, requires Quit, and does not claim that the original audio path was restored.

The application selector displays information macOS exposes for processes that are currently producing audio. VolEq does not intentionally persist that process list.

When the user chooses **Check for Updates**, or explicitly enables automatic checks, VolEq makes an unauthenticated request to `api.github.com` for the latest published VolEq Community release. Automatic checks run at most once in a rolling 24-hour period and only while VolEq is running. Opening **View Release** contacts `github.com`. GitHub receives ordinary network metadata such as the user's IP address. VolEq sends no audio, account identifier, user identifier, or usage telemetry, and it stores no GitHub response body, cookie, or credential. The setting can be changed in VolEq Settings.

This statement describes the current source tree. Contributors must update it before adding telemetry, additional networking, persistent recordings, crash reporting, or other data collection.
