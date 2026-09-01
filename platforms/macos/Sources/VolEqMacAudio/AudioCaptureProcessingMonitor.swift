// SPDX-License-Identifier: MPL-2.0

import CoreAudio
import Foundation

@MainActor
final class AudioCaptureProcessingMonitor {
    private var task: Task<Void, Never>?
    private let pollIntervalNanoseconds: UInt64

    init(pollIntervalNanoseconds: UInt64 = 100_000_000) {
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
    }

    func start(
        pipeline: any AudioCapturePipeline,
        runningStatus: String,
        isCurrent: @escaping @MainActor (any AudioCapturePipeline) -> Bool,
        onStatus: @escaping @MainActor (String) -> Void,
        onFailure: @escaping @MainActor (OSStatus) -> Void
    ) {
        stop()
        guard let processor = pipeline.processor else { return }
        task = Task { @MainActor [weak pipeline] in
            var processingPathStatusPublished = false
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
                guard let pipeline,
                      isCurrent(pipeline),
                      !Task.isCancelled
                else { return }
                if let failure = processor.takePendingFailure() {
                    onFailure(failure)
                    return
                }
                guard !processingPathStatusPublished,
                      let diagnostics = processor.currentDiagnostics()
                else { continue }
                onStatus(Self.status(
                    for: diagnostics,
                    processor: processor,
                    runningStatus: runningStatus
                ))
                processingPathStatusPublished = true
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private static func status(
        for diagnostics: AudioIOProcessingDiagnostics,
        processor: AudioIOProcessor,
        runningStatus: String
    ) -> String {
        switch diagnostics.path {
        case .directAggregateClock:
            guard processor.usesSampleRateConversion else {
                return runningStatus
            }
            return runningStatus
                + " Core Audio synchronized this route "
                + "(\(diagnostics.inputFrameCount)→"
                + "\(diagnostics.outputFrameCount) frames); duplicate "
                + "conversion is bypassed."
        case .sampleRateConverter:
            return runningStatus
                + " Output conversion is active "
                + "(\(diagnostics.inputFrameCount)→"
                + "\(diagnostics.outputFrameCount) callback frames; "
                + "\(Int(processor.inputSampleRate))→"
                + "\(Int(processor.outputSampleRate)) Hz)."
        }
    }
}
