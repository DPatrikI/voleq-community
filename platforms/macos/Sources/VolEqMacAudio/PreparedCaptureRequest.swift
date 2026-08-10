// SPDX-License-Identifier: MPL-2.0

import CoreAudio
import VolEqSpeech

struct PreparedCaptureRequest: @unchecked Sendable {
    let speechModel: RNNoiseModelResource?
    let outputDeviceID: AudioObjectID
    let outputDeviceUID: String
    let outputFormat: AudioStreamBasicDescription
    let captureTarget: AudioCaptureTarget
    let intent: CaptureIntent

    func replacingIntent(_ intent: CaptureIntent) -> PreparedCaptureRequest {
        PreparedCaptureRequest(
            speechModel: speechModel,
            outputDeviceID: outputDeviceID,
            outputDeviceUID: outputDeviceUID,
            outputFormat: outputFormat,
            captureTarget: captureTarget,
            intent: intent
        )
    }
}
