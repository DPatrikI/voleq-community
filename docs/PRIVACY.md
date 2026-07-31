# Privacy

VolEq processes captured application or device audio locally on the Mac. The
Community application does not record captured audio, write it to disk, upload
it, send it to an online service, or use it for telemetry.

Speech probability is calculated with a bundled RNNoise model. On macOS, the
operating system's offline sound classifier also distinguishes speech context
from music before VolEq permits upward gain. Captured samples reach it only
through an in-memory bounded queue. Analysis state, the learned background
level, and delayed audio exist only in memory while leveling is active and are
reset when the audio route is rebuilt or processing stops. Normal builds and
the finished application perform no model download.

macOS controls System Audio Recording permission. VolEq requests only the
permission needed for the selected capture mode. Device-wide capture excludes
VolEq's own process to prevent feedback.

This describes the current Community source tree. A future Premium application
must document any additional diagnostics or services separately before they are
introduced.
