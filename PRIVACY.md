# Privacy

VolEq Community processes captured audio locally in memory. Captured audio is never saved, uploaded, or used for telemetry. When speech-aware leveling is enabled, bundled RNNoise states analyze and mildly denoise speech. Turning speech awareness off skips RNNoise and speech analysis entirely. Apple's offline SoundAnalysis framework supplies the slower speech-versus-music decision. The application does not create user accounts or include analytics. Update checks never include captured audio or usage telemetry.

macOS controls access through System Audio Recording permission. VolEq explains its local-only audio use before the real processing pipeline causes macOS to present the permission prompt. VolEq does not infer permission from silence or run a separate permission probe. An ordinary Core Audio startup failure leaves VolEq non-running and begins complete graph teardown. If Core Audio refuses to stop or destroy a resource, VolEq retains ownership, requires Quit, and does not claim that the original audio path was restored. The always-visible **No sound?** help repeats the privacy guarantee and opens the relevant System Settings page.

The application selector displays information macOS exposes for processes that are currently producing audio. VolEq does not intentionally persist that process list.

When the user chooses **Check for Updates**, or explicitly enables automatic checks, VolEq makes an unauthenticated request to `api.github.com` for the latest published VolEq Community release. Automatic checks run at most once in a rolling 24-hour period and only while VolEq is running. Opening **View Release** contacts `github.com`. GitHub receives ordinary network metadata such as the user's IP address. VolEq sends no audio, account identifier, user identifier, or usage telemetry, and it stores no GitHub response body, cookie, or credential. The setting can be changed in VolEq Settings.

This statement describes the current source tree. Contributors must update it before adding telemetry, additional networking, persistent recordings, crash reporting, or other data collection.
