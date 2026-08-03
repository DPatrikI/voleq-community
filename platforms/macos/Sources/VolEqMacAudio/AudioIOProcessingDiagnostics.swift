// SPDX-License-Identifier: MPL-2.0

enum AudioSampleRatePath: Equatable {
    case directAggregateClock
    case sampleRateConverter
}

struct AudioIOProcessingDiagnostics: Equatable {
    let path: AudioSampleRatePath
    let inputFrameCount: Int
    let outputFrameCount: Int
}
