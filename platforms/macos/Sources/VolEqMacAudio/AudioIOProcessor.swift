// SPDX-License-Identifier: MPL-2.0

import AudioToolbox
import Foundation
import VolEqCore
import VolEqDSP
import VolEqSpeech

private let callbackTimingUnavailable = OSStatus(bitPattern: 0x5643_544D) // 'VCTM'
let speechAnalysisFailed = OSStatus(bitPattern: 0x5653_5048) // 'VSPH'

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
    private let diagnosticsLock = NSLock()
    private let failureLock = NSLock()
    private var sharedDiagnostics: AudioIOProcessingDiagnostics?
    private var pendingFailureStatus: OSStatus?
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
    }

    func updateSettings(_ settings: LevelingSettings) {
        directDynamics.updateSettings(settings)
        conversionDynamics.updateSettings(settings)
    }

    func currentDiagnostics() -> AudioIOProcessingDiagnostics? {
        diagnosticsLock.lock()
        defer { diagnosticsLock.unlock() }
        return sharedDiagnostics
    }

    /// Called by a control-thread monitor. Never call this from the audio callback.
    func takePendingFailure() -> OSStatus? {
        failureLock.lock()
        defer { failureLock.unlock() }
        let failure = pendingFailureStatus
        pendingFailureStatus = nil
        return failure
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

    func _testOnlyWithFailureLockHeld<Result>(
        _ body: () throws -> Result
    ) rethrows -> Result {
        failureLock.lock()
        defer { failureLock.unlock() }
        return try body()
    }
#endif

    func process(
        input: UnsafePointer<AudioBufferList>,
        inputTime: AudioTimeStamp? = nil,
        output: UnsafeMutablePointer<AudioBufferList>,
        outputTime: AudioTimeStamp? = nil
    ) {
        let inputFrameCount = Self.minimumAvailableFrameCount(in: input)
        let outputFrameCount = Self.minimumAvailableFrameCount(in: output)
        guard outputFrameCount > 0 else { return }
        guard inputFrameCount > 0 else {
            Self.clear(output: output)
            return
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
                return
            }
            return
        }

        let path: AudioSampleRatePath
        if let selectedPath {
            path = selectedPath
        } else {
            guard var cadenceAnalyzer else {
                Self.clear(output: output)
                reportConversionFailureIfNeeded(callbackTimingUnavailable)
                return
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
                return
            case let .resolved(resolvedPath):
                selectedPath = resolvedPath
                path = resolvedPath
            case .failed:
                Self.clear(output: output)
                reportConversionFailureIfNeeded(callbackTimingUnavailable)
                return
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
                return
            }
            return
        }

        conversionContentAnalyzer?.append(
            input: input,
            frameCount: inputFrameCount
        )
        guard sampleRateConverter.appendProcessedInput(input, processor: conversionDynamics) else {
            Self.clear(output: output)
            reportConversionFailureIfNeeded(speechAnalysisFailed)
            return
        }
        let result = sampleRateConverter.fillOutput(output)
        if let errorStatus = result.errorStatus {
            reportConversionFailureIfNeeded(errorStatus)
        }
    }

    private func reportConversionFailureIfNeeded(_ status: OSStatus) {
        guard !publishedFailure, failureLock.try() else { return }
        defer { failureLock.unlock() }
        guard pendingFailureStatus == nil else { return }
        pendingFailureStatus = status
        publishedFailure = true
    }

    private func recordDiagnosticsIfNeeded(
        path: AudioSampleRatePath,
        inputFrameCount: Int,
        outputFrameCount: Int
    ) {
        guard !diagnosticsRecorded, diagnosticsLock.try() else { return }
        defer { diagnosticsLock.unlock() }
        guard sharedDiagnostics == nil else { return }
        sharedDiagnostics = AudioIOProcessingDiagnostics(
            path: path,
            inputFrameCount: inputFrameCount,
            outputFrameCount: outputFrameCount
        )
        diagnosticsRecorded = true
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
