// SPDX-License-Identifier: MPL-2.0

import CoreAudio
import VolEqSpeech

enum AudioCaptureFailurePresentation {
    static func startFailure(
        _ error: Error,
        intent: CaptureIntent,
        isRecovery: Bool
    ) -> AudioCaptureLifecycleSnapshot {
        let message: String
        if case SpeechAnalyzerError.unsupportedSampleRate = error {
            message = "Speech-aware processing does not support the current audio sample rate. Original audio remains available. Turn off Speech-aware leveling to use base leveling."
        } else {
            message = error.localizedDescription
        }
        if isRecovery {
            return snapshot(
                .recoveryFailed(
                    intent,
                    .pipeline(message)
                ),
                "Leveling Did Not Resume — \(message) Original audio remains available."
            )
        }
        return snapshot(
            .failed(intent),
            message
        )
    }

    static func recoveryFailure(
        _ failure: RecoveryFailure,
        intent: CaptureIntent
    ) -> AudioCaptureLifecycleSnapshot {
        snapshot(
            .recoveryFailed(intent, failure),
            "Leveling Did Not Resume — \(failure.message) Original audio remains available."
        )
    }

    static func callbackStartupFailure(
        intent: CaptureIntent,
        isRecovery: Bool
    ) -> AudioCaptureLifecycleSnapshot {
        isRecovery
            ? snapshot(
                .recoveryFailed(intent, .callbacksDidNotStart),
                "Audio callbacks did not begin. Original audio was restored. Choose Try Again when the output route is ready."
            )
            : snapshot(
                .verifiedFailure(intent),
                "Audio callbacks did not begin. Original audio was restored. Try starting again when the output route is ready."
            )
    }

    static func processingFailure(
        _ statusCode: OSStatus,
        intent: CaptureIntent?
    ) -> AudioCaptureLifecycleSnapshot {
        let status = "Audio processing stopped after an internal conversion failure (OSStatus \(statusCode)). Original audio was restored. Try again after checking the current output device."
        return snapshot(
            intent.map(CaptureLifecyclePhase.verifiedFailure) ?? .failed(nil),
            status
        )
    }

    static let cleanupFailure = snapshot(
        CaptureLifecyclePhase.cleanupFailed,
        "VolEq could not fully stop its Core Audio resources. It will not start another pipeline. Quit VolEq to guarantee the original audio path is restored."
    )

    private static func snapshot(
        _ phase: CaptureLifecyclePhase,
        _ status: String
    ) -> AudioCaptureLifecycleSnapshot {
        AudioCaptureLifecycleSnapshot(phase: phase, status: status)
    }
}
