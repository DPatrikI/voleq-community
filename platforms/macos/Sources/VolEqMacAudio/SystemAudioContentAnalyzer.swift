// SPDX-License-Identifier: MPL-2.0

import AudioToolbox
import AVFAudio
import CoreMedia
import CVolEqRealtime
import Dispatch
import Foundation
import SoundAnalysis
import VolEqDSP

enum SystemAudioContentAnalyzerError: Error, LocalizedError {
    case stateAllocationFailed
    case audioFormatCreationFailed

    var errorDescription: String? {
        switch self {
        case .stateAllocationFailed:
            return "VolEq could not allocate its real-time content-analysis buffer."
        case .audioFormatCreationFailed:
            return "VolEq could not prepare the system sound classifier's audio format."
        }
    }
}

protocol AudioContentAnalyzing: UpwardGainAuthorizing {
    func append(
        input: UnsafePointer<AudioBufferList>,
        frameCount: Int
    )
}

struct SystemAudioContentDecision {
    enum Classification: Equatable {
        case speech
        case music
        case unknown
    }

    static let speechConfidenceThreshold = 0.22
    static let minimumSpeechToMusicRatio = 0.55
    static let musicVetoThreshold = 0.10

    private static let musicAndInstrumentIdentifiers: Set<String> = [
        "singing",
        "choir_singing",
        "acoustic_guitar",
        "bass_drum",
        "bass_guitar",
        "bowed_string_instrument",
        "brass_instrument",
        "drum",
        "drum_kit",
        "electric_guitar",
        "electric_piano",
        "guitar",
        "guitar_strum",
        "guitar_tapping",
        "keyboard_musical",
        "piano",
        "plucked_string_instrument",
        "rattle_instrument",
        "snare_drum",
        "steel_guitar_slide_guitar",
        "wind_instrument"
    ]

    static func classify(
        classifications: [(identifier: String, confidence: Double)]
    ) -> Classification {
        var speechConfidence = 0.0
        var genericMusicConfidence = 0.0
        var explicitMusicConfidence = 0.0
        var musicConfidence = 0.0
        for classification in classifications {
            guard classification.confidence.isFinite else { continue }
            if classification.identifier == "speech" {
                speechConfidence = max(speechConfidence, classification.confidence)
            }
            if classification.identifier == "music" {
                genericMusicConfidence = max(
                    genericMusicConfidence,
                    classification.confidence
                )
            }
            if musicAndInstrumentIdentifiers.contains(classification.identifier) {
                explicitMusicConfidence = max(
                    explicitMusicConfidence,
                    classification.confidence
                )
            }
        }
        musicConfidence = max(genericMusicConfidence, explicitMusicConfidence)

        if speechConfidence >= speechConfidenceThreshold,
           speechConfidence >= musicConfidence * minimumSpeechToMusicRatio {
            return .speech
        }
        return musicConfidence >= musicVetoThreshold ? .music : .unknown
    }
}

struct SystemAudioContentGate {
    static let speechConfirmationResultCount = 2
    static let uncertainSpeechHoldResultCount = 4

    private(set) var allowsUpwardGain = false
    private var consecutiveSpeechResultCount = 0
    private var uncertainHoldResultCount = 0

    mutating func observe(
        _ classification: SystemAudioContentDecision.Classification
    ) -> Bool {
        switch classification {
        case .music:
            allowsUpwardGain = false
            consecutiveSpeechResultCount = 0
            uncertainHoldResultCount = 0
        case .speech:
            consecutiveSpeechResultCount += 1
            if consecutiveSpeechResultCount
                >= Self.speechConfirmationResultCount {
                allowsUpwardGain = true
                uncertainHoldResultCount = Self.uncertainSpeechHoldResultCount
            }
        case .unknown:
            consecutiveSpeechResultCount = 0
            if allowsUpwardGain, uncertainHoldResultCount > 0 {
                uncertainHoldResultCount -= 1
            } else {
                allowsUpwardGain = false
            }
        }
        return allowsUpwardGain
    }

    mutating func reset() {
        allowsUpwardGain = false
        consecutiveSpeechResultCount = 0
        uncertainHoldResultCount = 0
    }
}

private final class RealtimeContentState: UpwardGainAuthorizing, @unchecked Sendable {
    private let state: OpaquePointer

    init(capacity: Int) throws {
        guard let state = voleq_realtime_content_state_create(capacity) else {
            throw SystemAudioContentAnalyzerError.stateAllocationFailed
        }
        self.state = state
    }

    deinit {
        voleq_realtime_content_state_destroy(state)
    }

    var allowsUpwardGain: Bool {
        voleq_realtime_content_state_is_speech_authorized(state)
    }

    func setAllowsUpwardGain(_ allows: Bool) {
        voleq_realtime_content_state_set_speech_authorized(state, allows)
    }

    func write(_ samples: UnsafePointer<Float>, count: Int) -> Int {
        voleq_realtime_content_state_write(state, samples, count)
    }

    func read(_ samples: UnsafeMutablePointer<Float>, count: Int) -> Int {
        voleq_realtime_content_state_read(state, samples, count)
    }
}

private final class SystemAudioContentObserver: NSObject, SNResultsObserving {
    private let state: RealtimeContentState
    private var gate = SystemAudioContentGate()

    init(state: RealtimeContentState) {
        self.state = state
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else {
            state.setAllowsUpwardGain(false)
            return
        }
        let classifications = result.classifications.map {
            (identifier: $0.identifier, confidence: $0.confidence)
        }
        let decision = SystemAudioContentDecision.classify(
            classifications: classifications
        )
        let allowsUpwardGain = gate.observe(decision)
        state.setAllowsUpwardGain(allowsUpwardGain)
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        state.setAllowsUpwardGain(false)
    }

    func requestDidComplete(_ request: SNRequest) {
        state.setAllowsUpwardGain(false)
    }

    func resetAfterInputGap() {
        gate.reset()
        state.setAllowsUpwardGain(false)
    }
}

final class SystemAudioContentAnalyzer: AudioContentAnalyzing, @unchecked Sendable {
    static let analysisWindowSeconds = 0.5
    static let overlapFactor = 0.5
    static let drainIntervalMilliseconds = 20
    static let inputGapResetDrainCount = 25

    private static let callbackScratchCapacity = 4_096
    private static let analysisBufferCapacity: AVAudioFrameCount = 4_096

    private let state: RealtimeContentState
    private let streamAnalyzer: SNAudioStreamAnalyzer
    private let observer: SystemAudioContentObserver
    private let analysisBuffer: AVAudioPCMBuffer
    private let inputGapFrameCount: AVAudioFramePosition
    private let analysisQueue = DispatchQueue(
        label: "com.dpatrik.iosif.voleq.content-analysis",
        qos: .utility
    )
    private let drainTimer: DispatchSourceTimer
    private var callbackScratch: [Float]
    private var analyzedFramePosition: AVAudioFramePosition = 0
    private var emptyDrainCount = 0

    init(sampleRate: Double) throws {
        let capacity = max(Int((sampleRate * 2).rounded(.up)), 8_192)
        let state = try RealtimeContentState(capacity: capacity)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ), let analysisBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: Self.analysisBufferCapacity
        ) else {
            throw SystemAudioContentAnalyzerError.audioFormatCreationFailed
        }

        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(
            seconds: Self.analysisWindowSeconds,
            preferredTimescale: 48_000
        )
        request.overlapFactor = Self.overlapFactor

        let observer = SystemAudioContentObserver(state: state)
        let streamAnalyzer = SNAudioStreamAnalyzer(format: format)
        try streamAnalyzer.add(request, withObserver: observer)

        let timer = DispatchSource.makeTimerSource(queue: analysisQueue)
        self.state = state
        self.streamAnalyzer = streamAnalyzer
        self.observer = observer
        self.analysisBuffer = analysisBuffer
        inputGapFrameCount = AVAudioFramePosition(
            (sampleRate * Self.analysisWindowSeconds).rounded()
        )
        drainTimer = timer
        callbackScratch = Array(
            repeating: 0,
            count: Self.callbackScratchCapacity
        )

        timer.setEventHandler { [weak self] in
            self?.drainQueuedAudio()
        }
        timer.schedule(
            deadline: .now(),
            repeating: .milliseconds(Self.drainIntervalMilliseconds),
            leeway: .milliseconds(5)
        )
        timer.resume()
    }

    deinit {
        state.setAllowsUpwardGain(false)
        drainTimer.setEventHandler {}
        drainTimer.cancel()
        streamAnalyzer.removeAllRequests()
    }

    var allowsUpwardGain: Bool {
        state.allowsUpwardGain
    }

    func append(
        input: UnsafePointer<AudioBufferList>,
        frameCount: Int
    ) {
        guard frameCount > 0 else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: input)
        )
        let channelCount = totalChannelCount(in: buffers)
        guard channelCount > 0 else { return }

        var frameOffset = 0
        while frameOffset < frameCount {
            let chunkCount = min(
                callbackScratch.count,
                frameCount - frameOffset
            )
            for frame in 0..<chunkCount {
                let sourceFrame = frameOffset + frame
                let left = sample(
                    from: buffers,
                    channel: 0,
                    frame: sourceFrame
                )
                let right = sample(
                    from: buffers,
                    channel: min(1, channelCount - 1),
                    frame: sourceFrame
                )
                callbackScratch[frame] = (left + right) * 0.5
            }
            callbackScratch.withUnsafeBufferPointer { samples in
                guard let baseAddress = samples.baseAddress else { return }
                _ = state.write(baseAddress, count: chunkCount)
            }
            frameOffset += chunkCount
        }
    }

    private func drainQueuedAudio() {
        guard let channel = analysisBuffer.floatChannelData?[0] else {
            state.setAllowsUpwardGain(false)
            return
        }
        let count = state.read(
            channel,
            count: Int(analysisBuffer.frameCapacity)
        )
        guard count > 0 else {
            emptyDrainCount += 1
            if emptyDrainCount == Self.inputGapResetDrainCount {
                observer.resetAfterInputGap()
                // The next frame position deliberately skips one classifier
                // window. SoundAnalysis treats the timeline discontinuity as a
                // boundary instead of blending pre-gap speech with new content.
                analyzedFramePosition += inputGapFrameCount
            }
            return
        }
        emptyDrainCount = 0
        analysisBuffer.frameLength = AVAudioFrameCount(count)
        streamAnalyzer.analyze(
            analysisBuffer,
            atAudioFramePosition: analyzedFramePosition
        )
        analyzedFramePosition += AVAudioFramePosition(count)
    }

    @inline(__always)
    private func totalChannelCount(
        in buffers: UnsafeMutableAudioBufferListPointer
    ) -> Int {
        var total = 0
        var index = 0
        while index < buffers.count {
            total += Int(buffers[index].mNumberChannels)
            index += 1
        }
        return total
    }

    @inline(__always)
    private func sample(
        from buffers: UnsafeMutableAudioBufferListPointer,
        channel wantedChannel: Int,
        frame: Int
    ) -> Float {
        var channelOffset = 0
        for buffer in buffers {
            let channelCount = Int(buffer.mNumberChannels)
            guard wantedChannel < channelOffset + channelCount else {
                channelOffset += channelCount
                continue
            }
            guard let data = buffer.mData else { return 0 }
            let localChannel = wantedChannel - channelOffset
            return data.assumingMemoryBound(to: Float.self)[
                frame * channelCount + localChannel
            ]
        }
        return 0
    }
}
