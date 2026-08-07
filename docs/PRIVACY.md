# Privacy

VolEq processes captured application or device audio locally on the Mac. The
Community application does not record captured audio, write it to disk, upload
it, send it to an online service, or use it for telemetry.

When speech-aware leveling is enabled, speech probability and denoised samples
are calculated with one prepared RNNoise state per channel using the same
bundled model, and mild suppression is applied automatically when its speech and
noise conditions are met. Turning speech awareness off skips RNNoise and speech
analysis entirely. On macOS, the operating system's offline sound classifier
also distinguishes speech context from music before VolEq permits upward gain
or suppression. Captured samples reach it only
through an in-memory bounded queue. RNNoise input/output, analysis state, the
learned background level, and delayed audio exist only in memory while leveling
is active and are reset when the audio route is rebuilt or processing stops.
Normal builds and the finished application perform no model download. No new
model, online classifier, account, or service is used for mild suppression.

## Update checks

A user-initiated **Check for Updates** action contacts GitHub even when
automatic checks are disabled. Automatic checks remain off until the user makes
an explicit choice. When enabled, VolEq contacts
`https://api.github.com/repos/DPatrikI/voleq-community/releases/latest` at most
once per rolling 24-hour period while the application is running. VolEq has no
background daemon and does not check while it is closed.

The request is unauthenticated and contains only normal GitHub API headers and a
VolEq product user agent. It sends no captured audio, speech decisions, process
list, account identifier, installation identifier, or usage telemetry. The
ephemeral network session does not persist a response cache, cookies, or
credentials. VolEq persists only the consent and enabled decisions, launch
count, last automatic-attempt date, last completed status, and last known
available version. It does not persist GitHub response bodies or network
metadata.

Choosing **View Release** opens a validated `https://github.com` VolEq release
page in the default browser. VolEq never downloads, executes, or installs an
update. GitHub receives ordinary network metadata for these requests, including
the user's IP address. GitHub's own privacy terms apply to its service.

macOS controls System Audio Recording permission. VolEq requests only the
permission needed for the selected capture mode. Device-wide capture excludes
VolEq's own process to prevent feedback.

This describes the current Community source tree. A future Premium application
must document any additional diagnostics or services separately before they are
introduced.
