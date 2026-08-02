# Privacy

VolEq processes captured application or device audio locally on the Mac. The
Community application does not record captured audio, write it to disk, upload
it, send it to an online service, or use it for telemetry.

When mild suppression is enabled, speech probability and denoised samples are
calculated with one prepared RNNoise state per channel using the same bundled
model. Turning only suppression off uses one mono RNNoise analysis state per
prepared route path and never applies denoised samples. On macOS, the operating
system's offline sound classifier also distinguishes speech context from music
before VolEq permits upward gain or suppression. Captured samples reach it only
through an in-memory bounded queue. RNNoise input/output, analysis state, the
learned background level, and delayed audio exist only in memory while leveling
is active and are reset when the audio route is rebuilt or processing stops.
Normal builds and the finished application perform no model download. No new
model, online classifier, account, or service is used for mild suppression.

macOS controls System Audio Recording permission. VolEq requests only the
permission needed for the selected capture mode. Device-wide capture excludes
VolEq's own process to prevent feedback.

This describes the current Community source tree. A future Premium application
must document any additional diagnostics or services separately before they are
introduced.
