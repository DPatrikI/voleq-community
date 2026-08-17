// SPDX-License-Identifier: MPL-2.0

import AudioToolbox
import CVolEqRealtime
import Foundation
import VolEqCore
import VolEqDSP
import VolEqSpeech

private let callbackTimingUnavailable = OSStatus(bitPattern: 0x5643_544D) // 'VCTM'
let speechAnalysisFailed = OSStatus(bitPattern: 0x5653_5048) // 'VSPH'

struct AudioIOCallbackMetadata {
    let inputFrameCount: Int
    let outputFrameCount: Int
    let capturedPeak: Float
    let flags: UInt32
    let path: UInt32
    let outcome: UInt32
    let status: Int32
}

private struct CapturedInputStatistics {
    let peak: Float
    let hasSamples: Bool
    let containsNonfiniteSample: Bool
}

/// Owns the direct and converted processing paths for one active audio route.
///
/// Construction prepares every dynamics, analysis, and conversion resource
/// before callbacks begin. The serial callback resolves the route clock once,
/// then keeps the selected path stable for the lifetime of this processor.
final class AudioIOProcessor {
    let usesSampleRateConversion: Bool
    let inputSampleRate: Double
    let outputSampleRate: Double
    let directProcessingLatencyFrameCount: Int
    let conversionProcessingLatencyFrameCount: Int

    private let directDynamics: DynamicsProcessor
    private let conversionDynamics: DynamicsProcessor
    private let directContentAnalyzer: (any AudioContentAnalyzing)?
    private let conversionContentAnalyzer: (any AudioContentAnalyzing)?
    private let sampleRateConverter: BufferedSampleRateConverter?
    private let realtimePublication: OpaquePointer
    private var cadenceAnalyzer: AudioCallbackCadenceAnalyzer?
    private var selectedPath: AudioSampleRatePath?
    /// Written only by the serial audio callback; avoids a lock attempt per period.
    private var diagnosticsRecorded = false
    private var publishedFailure = false

    private static let sharedSpeechModel = Result<RNNoiseModelResource, Error> {
        try RNNoiseModelResource.bundled()
    }

    static func loadSpeechModel() throws -> RNNoiseModelResource {
        try sharedSpeechModel.get()
    }

    init(
        inputFormat: AudioStreamBasicDescription,
        outputFormat: AudioStreamBasicDescription,
        settings: LevelingSettings,
        speechAwarenessEnabled: Bool = true,
        speechModel: RNNoiseModelResource? = nil,
        speechAnalyzerFactory: ((Double) throws -> any SpeechAnalyzing)? = nil,
        stereoSpeechProcessorFactory: ((Double) throws -> any StereoSpeechProcessing)? = nil,
        contentAnalyzerFactory: ((Double) throws -> any AudioContentAnalyzing)? = nil,
        systemContentAnalysisEnabled: Bool = false
    ) throws {
        inputSampleRate = inputFormat.mSampleRate
        outputSampleRate = outputFormat.mSampleRate
        if speechAwarenessEnabled {
            // Reject both possible processing clocks on the control thread
            // before analysis, conversion, or callback resources exist.
            _ = try RNNoiseFixedBlockSampleRate.sourceBlockFrameCount(
                for: outputFormat.mSampleRate
            )
            _ = try RNNoiseFixedBlockSampleRate.sourceBlockFrameCount(
                for: inputFormat.mSampleRate
            )
            let directContentAnalyzer: (any AudioContentAnalyzing)?
            let conversionContentAnalyzer: (any AudioContentAnalyzing)?
            if let contentAnalyzerFactory {
                directContentAnalyzer = try contentAnalyzerFactory(
                    outputFormat.mSampleRate
                )
                if abs(inputFormat.mSampleRate - outputFormat.mSampleRate) < 1 {
                    conversionContentAnalyzer = directContentAnalyzer
                } else {
                    conversionContentAnalyzer = try contentAnalyzerFactory(
                        inputFormat.mSampleRate
                    )
                }
            } else if systemContentAnalysisEnabled {
                directContentAnalyzer = try SystemAudioContentAnalyzer(
                    sampleRate: outputFormat.mSampleRate
                )
                if abs(inputFormat.mSampleRate - outputFormat.mSampleRate) < 1 {
                    conversionContentAnalyzer = directContentAnalyzer
                } else {
                    conversionContentAnalyzer = try SystemAudioContentAnalyzer(
                        sampleRate: inputFormat.mSampleRate
                    )
                }
            } else {
                directContentAnalyzer = nil
                conversionContentAnalyzer = nil
            }
            self.directContentAnalyzer = directContentAnalyzer
            self.conversionContentAnalyzer = conversionContentAnalyzer
            if let speechAnalyzerFactory {
                let directAnalyzer = try speechAnalyzerFactory(outputFormat.mSampleRate)
                let conversionAnalyzer = try speechAnalyzerFactory(inputFormat.mSampleRate)
                directDynamics = try DynamicsProcessor(
                    sampleRate: outputFormat.mSampleRate,
                    settings: settings,
                    speechAnalyzer: directAnalyzer,
                    upwardGainAuthorizer: directContentAnalyzer
                )
                conversionDynamics = try DynamicsProcessor(
                    sampleRate: inputFormat.mSampleRate,
                    settings: settings,
                    speechAnalyzer: conversionAnalyzer,
                    upwardGainAuthorizer: conversionContentAnalyzer
                )
            } else {
                let model = try speechModel ?? Self.loadSpeechModel()
                let directProcessor = try stereoSpeechProcessorFactory?(
                    outputFormat.mSampleRate
                ) ?? RNNoiseStereoProcessor(
                    sampleRate: outputFormat.mSampleRate,
                    model: model
                )
                let conversionProcessor = try stereoSpeechProcessorFactory?(
                    inputFormat.mSampleRate
                ) ?? RNNoiseStereoProcessor(
                    sampleRate: inputFormat.mSampleRate,
                    model: model
                )
                directDynamics = try DynamicsProcessor(
                    sampleRate: outputFormat.mSampleRate,
                    settings: settings,
                    stereoSpeechProcessor: directProcessor,
                    upwardGainAuthorizer: directContentAnalyzer
                )
                conversionDynamics = try DynamicsProcessor(
                    sampleRate: inputFormat.mSampleRate,
                    settings: settings,
                    stereoSpeechProcessor: conversionProcessor,
                    upwardGainAuthorizer: conversionContentAnalyzer
                )
            }
        } else {
            directContentAnalyzer = nil
            conversionContentAnalyzer = nil
            directDynamics = DynamicsProcessor(
                sampleRate: outputFormat.mSampleRate,
                settings: settings
            )
            conversionDynamics = DynamicsProcessor(
                sampleRate: inputFormat.mSampleRate,
                settings: settings
            )
        }
        directProcessingLatencyFrameCount = directDynamics.latencyFrameCount
        conversionProcessingLatencyFrameCount = conversionDynamics.latencyFrameCount
        if abs(inputFormat.mSampleRate - outputFormat.mSampleRate) >= 1 {
            sampleRateConverter = try BufferedSampleRateConverter(
                inputSampleRate: inputFormat.mSampleRate,
                outputFormat: outputFormat
            )
            cadenceAnalyzer = AudioCallbackCadenceAnalyzer(
                inputSampleRate: inputFormat.mSampleRate,
                outputSampleRate: outputFormat.mSampleRate
            )
            usesSampleRateConversion = true
        } else {
            sampleRateConverter = nil
            cadenceAnalyzer = nil
            usesSampleRateConversion = false
            selectedPath = .directAggregateClock
        }
        guard let realtimePublication =
            voleq_realtime_processor_publication_create() else {
            throw VolEqError.missingValue(
                "VolEq could not allocate its real-time processor state."
            )
        }
        self.realtimePublication = realtimePublication
    }

    deinit {
        voleq_realtime_processor_publication_destroy(realtimePublication)
    }

    func updateSettings(_ settings: LevelingSettings) {
        directDynamics.updateSettings(settings)
        conversionDynamics.updateSettings(settings)
    }

    func currentDiagnostics() -> AudioIOProcessingDiagnostics? {
        var path: UInt32 = 0
        var inputFrameCount: UInt32 = 0
        var outputFrameCount: UInt32 = 0
        guard voleq_realtime_processor_read_diagnostics(
            realtimePublication,
            &path,
            &inputFrameCount,
            &outputFrameCount
        ) else { return nil }
        let resolvedPath: AudioSampleRatePath
        switch path {
        case 1: resolvedPath = .directAggregateClock
        case 2: resolvedPath = .sampleRateConverter
        default: return nil
        }
        return AudioIOProcessingDiagnostics(
            path: resolvedPath,
            inputFrameCount: Int(inputFrameCount),
            outputFrameCount: Int(outputFrameCount)
        )
    }

    /// Called by a control-thread monitor. Never call this from the audio callback.
    func takePendingFailure() -> OSStatus? {
        let failure = voleq_realtime_processor_take_failure(
            realtimePublication
        )
        return failure == noErr ? nil : failure
    }

#if DEBUG
    /// Test-only hooks used to prove callback paths skip contended control locks.
    func _testOnlyWithParameterLocksHeld<Result>(
        _ body: () throws -> Result
    ) rethrows -> Result {
        try directDynamics._testOnlyWithParameterLockHeld {
            try conversionDynamics._testOnlyWithParameterLockHeld(body)
        }
    }

#endif

    func process(
        input: UnsafePointer<AudioBufferList>,
        inputTime: AudioTimeStamp? = nil,
        output: UnsafeMutablePointer<AudioBufferList>,
        outputTime: AudioTimeStamp? = nil
    ) {
        _ = process(
            input: input,
            inputTime: inputTime,
            output: output,
            outputTime: outputTime,
            collectInputStatistics: false
        )
    }

    func processWithDiagnostics(
        input: UnsafePointer<AudioBufferList>,
        inputTime: AudioTimeStamp? = nil,
        output: UnsafeMutablePointer<AudioBufferList>,
        outputTime: AudioTimeStamp? = nil
    ) -> AudioIOCallbackMetadata {
        process(
            input: input,
            inputTime: inputTime,
            output: output,
            outputTime: outputTime,
            collectInputStatistics: true
        )
    }

    /// Diagnostic-build fault injection. The caller gates this with a
    /// preallocated atomic flag; this method performs only bounded callback
    /// work and deliberately emits no captured samples.
    func processSimulatedUnusableCapture(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>
    ) -> AudioIOCallbackMetadata {
        let inputFrameCount = Self.minimumAvailableFrameCount(in: input)
        let outputFrameCount = Self.minimumAvailableFrameCount(in: output)
        Self.clear(output: output)
        return callbackMetadata(
            inputFrameCount: inputFrameCount,
            outputFrameCount: outputFrameCount,
            inputStatistics: CapturedInputStatistics(
                peak: 0,
                hasSamples: inputFrameCount > 0,
                containsNonfiniteSample: false
            ),
            path: selectedPath,
            outcome: 4,
            status: noErr,
            collected: true
        )
    }

    private func process(
        input: UnsafePointer<AudioBufferList>,
        inputTime: AudioTimeStamp?,
        output: UnsafeMutablePointer<AudioBufferList>,
        outputTime: AudioTimeStamp?,
        collectInputStatistics: Bool
    ) -> AudioIOCallbackMetadata {
        let inputFrameCount = Self.minimumAvailableFrameCount(in: input)
        let outputFrameCount = Self.minimumAvailableFrameCount(in: output)
        let inputStatistics: CapturedInputStatistics
        if collectInputStatistics {
            inputStatistics = Self.capturedInputStatistics(
                in: input,
                frameCount: inputFrameCount
            )
        } else {
            inputStatistics = CapturedInputStatistics(
                peak: 0,
                hasSamples: false,
                containsNonfiniteSample: false
            )
        }
        guard outputFrameCount > 0 else {
            return callbackMetadata(
                inputFrameCount: inputFrameCount,
                outputFrameCount: outputFrameCount,
                inputStatistics: inputStatistics,
                path: selectedPath,
                outcome: 1,
                status: noErr,
                collected: collectInputStatistics
            )
        }
        guard inputFrameCount > 0 else {
            Self.clear(output: output)
            return callbackMetadata(
                inputFrameCount: inputFrameCount,
                outputFrameCount: outputFrameCount,
                inputStatistics: inputStatistics,
                path: selectedPath,
                outcome: 2,
                status: noErr,
                collected: collectInputStatistics
            )
        }
        guard let sampleRateConverter else {
            directContentAnalyzer?.append(
                input: input,
                frameCount: inputFrameCount
            )
            recordDiagnosticsIfNeeded(
                path: .directAggregateClock,
                inputFrameCount: inputFrameCount,
                outputFrameCount: outputFrameCount
            )
            guard directDynamics.process(input: input, output: output) else {
                Self.clear(output: output)
                reportConversionFailureIfNeeded(speechAnalysisFailed)
                return callbackMetadata(
                    inputFrameCount: inputFrameCount,
                    outputFrameCount: outputFrameCount,
                    inputStatistics: inputStatistics,
                    path: .directAggregateClock,
                    outcome: 5,
                    status: speechAnalysisFailed,
                    collected: collectInputStatistics
                )
            }
            return callbackMetadata(
                inputFrameCount: inputFrameCount,
                outputFrameCount: outputFrameCount,
                inputStatistics: inputStatistics,
                path: .directAggregateClock,
                outcome: 4,
                status: noErr,
                collected: collectInputStatistics
            )
        }

        let path: AudioSampleRatePath
        if let selectedPath {
            path = selectedPath
        } else {
            guard var cadenceAnalyzer else {
                Self.clear(output: output)
                reportConversionFailureIfNeeded(callbackTimingUnavailable)
                return callbackMetadata(
                    inputFrameCount: inputFrameCount,
                    outputFrameCount: outputFrameCount,
                    inputStatistics: inputStatistics,
                    path: nil,
                    outcome: 5,
                    status: callbackTimingUnavailable,
                    collected: collectInputStatistics
                )
            }
            let resolution = cadenceAnalyzer.observe(
                inputFrameCount: inputFrameCount,
                inputTime: inputTime,
                outputFrameCount: outputFrameCount,
                outputTime: outputTime
            )
            self.cadenceAnalyzer = cadenceAnalyzer
            switch resolution {
            case .pending:
                Self.clear(output: output)
                return callbackMetadata(
                    inputFrameCount: inputFrameCount,
                    outputFrameCount: outputFrameCount,
                    inputStatistics: inputStatistics,
                    path: nil,
                    outcome: 3,
                    status: noErr,
                    collected: collectInputStatistics
                )
            case let .resolved(resolvedPath):
                selectedPath = resolvedPath
                path = resolvedPath
            case .failed:
                Self.clear(output: output)
                reportConversionFailureIfNeeded(callbackTimingUnavailable)
                return callbackMetadata(
                    inputFrameCount: inputFrameCount,
                    outputFrameCount: outputFrameCount,
                    inputStatistics: inputStatistics,
                    path: nil,
                    outcome: 5,
                    status: callbackTimingUnavailable,
                    collected: collectInputStatistics
                )
            }
        }
        recordDiagnosticsIfNeeded(
            path: path,
            inputFrameCount: inputFrameCount,
            outputFrameCount: outputFrameCount
        )

        guard path == .sampleRateConverter else {
            directContentAnalyzer?.append(
                input: input,
                frameCount: inputFrameCount
            )
            guard directDynamics.process(input: input, output: output) else {
                Self.clear(output: output)
                reportConversionFailureIfNeeded(speechAnalysisFailed)
                return callbackMetadata(
                    inputFrameCount: inputFrameCount,
                    outputFrameCount: outputFrameCount,
                    inputStatistics: inputStatistics,
                    path: path,
                    outcome: 5,
                    status: speechAnalysisFailed,
                    collected: collectInputStatistics
                )
            }
            return callbackMetadata(
                inputFrameCount: inputFrameCount,
                outputFrameCount: outputFrameCount,
                inputStatistics: inputStatistics,
                path: path,
                outcome: 4,
                status: noErr,
                collected: collectInputStatistics
            )
        }

        conversionContentAnalyzer?.append(
            input: input,
            frameCount: inputFrameCount
        )
        guard sampleRateConverter.appendProcessedInput(input, processor: conversionDynamics) else {
            Self.clear(output: output)
            reportConversionFailureIfNeeded(speechAnalysisFailed)
            return callbackMetadata(
                inputFrameCount: inputFrameCount,
                outputFrameCount: outputFrameCount,
                inputStatistics: inputStatistics,
                path: path,
                outcome: 5,
                status: speechAnalysisFailed,
                collected: collectInputStatistics
            )
        }
        let result = sampleRateConverter.fillOutput(output)
        if let errorStatus = result.errorStatus {
            reportConversionFailureIfNeeded(errorStatus)
        }
        return callbackMetadata(
            inputFrameCount: inputFrameCount,
            outputFrameCount: outputFrameCount,
            inputStatistics: inputStatistics,
            path: path,
            outcome: result.errorStatus == nil ? 4 : 5,
            status: result.errorStatus ?? noErr,
            collected: collectInputStatistics
        )
    }

    private func callbackMetadata(
        inputFrameCount: Int,
        outputFrameCount: Int,
        inputStatistics: CapturedInputStatistics,
        path: AudioSampleRatePath?,
        outcome: UInt32,
        status: OSStatus,
        collected: Bool
    ) -> AudioIOCallbackMetadata {
        var flags: UInt32 = 0
        if outputFrameCount > 0 {
            flags |= UInt32(VOLEQ_DIAGNOSTIC_FLAG_OUTPUT_REQUEST_ACTIVE)
        }
        if inputFrameCount == 0 {
            flags |= UInt32(VOLEQ_DIAGNOSTIC_FLAG_NO_CAPTURED_FRAMES)
        }
        if collected,
           inputStatistics.hasSamples,
           !inputStatistics.containsNonfiniteSample,
           inputStatistics.peak == 0 {
            flags |= UInt32(VOLEQ_DIAGNOSTIC_FLAG_ALL_ZERO)
        }
        if inputStatistics.containsNonfiniteSample {
            flags |= UInt32(VOLEQ_DIAGNOSTIC_FLAG_NONFINITE_INPUT)
        }
        if inputFrameCount > 0,
           Self.isPartialDelivery(
               inputFrameCount: inputFrameCount,
               outputFrameCount: outputFrameCount,
               inputSampleRate: inputSampleRate,
               outputSampleRate: outputSampleRate,
               path: path
           ) {
            flags |= UInt32(VOLEQ_DIAGNOSTIC_FLAG_PARTIAL_DELIVERY)
        }
        let pathValue: UInt32
        switch path {
        case .directAggregateClock: pathValue = 1
        case .sampleRateConverter: pathValue = 2
        case nil: pathValue = 0
        }
        return AudioIOCallbackMetadata(
            inputFrameCount: inputFrameCount,
            outputFrameCount: outputFrameCount,
            capturedPeak: inputStatistics.peak,
            flags: flags,
            path: pathValue,
            outcome: outcome,
            status: status
        )
    }

    private static func isPartialDelivery(
        inputFrameCount: Int,
        outputFrameCount: Int,
        inputSampleRate: Double,
        outputSampleRate: Double,
        path: AudioSampleRatePath?
    ) -> Bool {
        guard outputFrameCount > 0 else { return false }
        let expectedInputFrameCount: Int
        if path != .directAggregateClock,
           inputSampleRate.isFinite,
           outputSampleRate.isFinite,
           outputSampleRate > 0 {
            expectedInputFrameCount = Int(ceil(
                Double(outputFrameCount) * inputSampleRate / outputSampleRate
            ))
        } else {
            expectedInputFrameCount = outputFrameCount
        }
        return inputFrameCount + 1 < expectedInputFrameCount
    }

    private func reportConversionFailureIfNeeded(_ status: OSStatus) {
        guard !publishedFailure else { return }
        voleq_realtime_processor_publish_failure(realtimePublication, status)
        publishedFailure = true
    }

    private func recordDiagnosticsIfNeeded(
        path: AudioSampleRatePath,
        inputFrameCount: Int,
        outputFrameCount: Int
    ) {
        guard !diagnosticsRecorded else { return }
        let pathValue: UInt32 = path == .directAggregateClock ? 1 : 2
        diagnosticsRecorded = voleq_realtime_processor_publish_diagnostics(
            realtimePublication,
            pathValue,
            UInt32(clamping: inputFrameCount),
            UInt32(clamping: outputFrameCount)
        )
    }

    private static func minimumAvailableFrameCount(
        in list: UnsafePointer<AudioBufferList>
    ) -> Int {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: list)
        )
        var accumulator = AudioBufferFrameCountAccumulator()
        for buffer in buffers {
            accumulator.include(
                channelCount: buffer.mNumberChannels,
                dataByteSize: buffer.mDataByteSize,
                hasData: buffer.mData != nil
            )
        }
        return accumulator.value
    }

    private static func capturedInputStatistics(
        in list: UnsafePointer<AudioBufferList>,
        frameCount: Int
    ) -> CapturedInputStatistics {
        guard frameCount > 0 else {
            return CapturedInputStatistics(
                peak: 0,
                hasSamples: false,
                containsNonfiniteSample: false
            )
        }
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: list)
        )
        var peak: Float = 0
        var hasSamples = false
        var containsNonfiniteSample = false
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let sampleCount = frameCount * Int(buffer.mNumberChannels)
            let samples = data.assumingMemoryBound(to: Float.self)
            for index in 0..<sampleCount {
                let sample = samples[index]
                guard sample.isFinite else {
                    containsNonfiniteSample = true
                    continue
                }
                hasSamples = true
                peak = max(peak, abs(sample))
            }
        }
        return CapturedInputStatistics(
            peak: peak,
            hasSamples: hasSamples,
            containsNonfiniteSample: containsNonfiniteSample
        )
    }

    private static func minimumAvailableFrameCount(
        in list: UnsafeMutablePointer<AudioBufferList>
    ) -> Int {
        minimumAvailableFrameCount(in: UnsafePointer(list))
    }

    private static func clear(output list: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            memset(data, 0, Int(buffer.mDataByteSize))
        }
    }
}
