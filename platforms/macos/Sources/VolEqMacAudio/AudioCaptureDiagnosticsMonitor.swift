// SPDX-License-Identifier: MPL-2.0

import CoreAudio
import Foundation

@MainActor
final class AudioCaptureDiagnosticsMonitor {
    private var task: Task<Void, Never>?

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
            var diagnosticsRecorded = false
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let pipeline,
                      isCurrent(pipeline),
                      !Task.isCancelled
                else { return }
                if let failure = processor.takePendingFailure() {
                    onFailure(failure)
                    return
                }
                guard !diagnosticsRecorded,
                      let diagnostics = processor.currentDiagnostics()
                else { continue }

                switch diagnostics.path {
                case .directAggregateClock:
                    onStatus(processor.usesSampleRateConversion
                        ? runningStatus + " Core Audio synchronized this route (\(diagnostics.inputFrameCount)→\(diagnostics.outputFrameCount) frames); duplicate conversion is bypassed."
                        : runningStatus)
                case .sampleRateConverter:
                    onStatus(
                        runningStatus + " Output conversion is active (\(diagnostics.inputFrameCount)→\(diagnostics.outputFrameCount) callback frames; \(Int(processor.inputSampleRate))→\(Int(processor.outputSampleRate)) Hz)."
                    )
                }
                diagnosticsRecorded = true
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
