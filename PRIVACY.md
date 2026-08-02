# Privacy

VolEq Community processes captured audio locally in memory. When mild suppression is enabled, bundled RNNoise states analyze and mildly denoise speech; turning only suppression off keeps mono RNNoise speech analysis active but never applies denoised samples. Apple's offline SoundAnalysis framework supplies the slower speech-versus-music decision. The current application does not intentionally record audio to disk, transmit audio, create user accounts, include analytics, or contact a VolEq server.

macOS controls access through System Audio Recording permission. VolEq requests access because it must capture selected outgoing application audio before leveling and replaying it to the current output device.

The application selector displays information macOS exposes for processes that are currently producing audio. VolEq does not intentionally persist that process list.

This statement describes the current source tree. Contributors must update it before adding telemetry, networking, persistent recordings, crash reporting, or other data collection.
