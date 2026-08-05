// SPDX-License-Identifier: MPL-2.0

import AudioToolbox
import VolEqCore
import VolEqSpeech
import XCTest
@testable import VolEqMacAudio

class AudioPipelineTestCase: XCTestCase {
    func assertSamplesBitExact(
        _ actual: [Float],
        _ expected: [Float],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for index in actual.indices {
            XCTAssertEqual(
                actual[index].bitPattern,
                expected[index].bitPattern,
                "Float bit-pattern mismatch at interleaved index \(index)",
                file: file,
                line: line
            )
        }
    }

    func withInterleavedStereoBuffer<Result>(
        samples: inout [Float],
        body: (UnsafePointer<AudioBufferList>) throws -> Result
    ) rethrows -> Result {
        try samples.withUnsafeMutableBytes { bytes in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: UInt32(bytes.count),
                    mData: bytes.baseAddress
                )
            )
            return try withUnsafePointer(to: &list, body)
        }
    }

    func withMutableInterleavedBuffer<Result>(
        samples: inout [Float],
        channelCount: UInt32,
        body: (UnsafeMutablePointer<AudioBufferList>) throws -> Result
    ) rethrows -> Result {
        try samples.withUnsafeMutableBytes { bytes in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: channelCount,
                    mDataByteSize: UInt32(bytes.count),
                    mData: bytes.baseAddress
                )
            )
            return try withUnsafeMutablePointer(to: &list, body)
        }
    }

    func floatFormat(
        sampleRate: Double,
        channelCount: UInt32
    ) -> AudioStreamBasicDescription {
        let bytesPerFrame = channelCount * UInt32(MemoryLayout<Float>.stride)
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    func hostTimestamp(_ hostTime: UInt64) -> AudioTimeStamp {
        var timestamp = AudioTimeStamp()
        timestamp.mHostTime = hostTime
        timestamp.mFlags = .hostTimeValid
        return timestamp
    }

    func neutralSettings() -> LevelingSettings {
        LevelingSettings(
            thresholdDB: 0,
            compressorRatio: 1,
            quietCompressionRatio: 1,
            quietPriorityDB: 0,
            noiseGateDB: -160,
            expanderRatio: 1,
            makeupGainDB: 0,
            limiterDB: 0
        )
    }
}

enum TestSpeechFailure: Error {
    case startup
}

final class PendingSpeechAnalyzer: SpeechAnalyzing {
    let sourceSampleRate: Double
    let sourceBlockFrameCount: Int
    let analysisLatencyFrameCount = 0

    init(sampleRate: Double) {
        sourceSampleRate = sampleRate
        sourceBlockFrameCount = try! RNNoiseFixedBlockSampleRate.sourceBlockFrameCount(
            for: sampleRate
        )
    }

    func processMonoSample(_: Float) -> SpeechAnalysisEvent { .pending }
    func reset() {}
}

final class FailingSpeechAnalyzer: SpeechAnalyzing {
    let sourceSampleRate: Double
    let sourceBlockFrameCount = 1
    let analysisLatencyFrameCount = 1
    private let failAfterSampleCount: Int
    private var processedSampleCount = 0

    init(sampleRate: Double, failAfterSampleCount: Int) {
        sourceSampleRate = sampleRate
        self.failAfterSampleCount = failAfterSampleCount
    }

    func processMonoSample(_: Float) -> SpeechAnalysisEvent {
        processedSampleCount += 1
        return processedSampleCount >= failAfterSampleCount ? .failed : .pending
    }

    func reset() {
        processedSampleCount = 0
    }
}

final class AnalyzerCreationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: Double) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

final class ContentAnalyzerRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var analyzers: [RecordingContentAnalyzer] = []

    func make(sampleRate: Double) -> RecordingContentAnalyzer {
        let analyzer = RecordingContentAnalyzer(sampleRate: sampleRate)
        lock.lock()
        analyzers.append(analyzer)
        lock.unlock()
        return analyzer
    }

    func appendedFrameCount(at sampleRate: Double) -> Int {
        lock.lock()
        let analyzer = analyzers.first { abs($0.sampleRate - sampleRate) < 0.5 }
        lock.unlock()
        return analyzer?.appendedFrameCount ?? 0
    }
}

final class RecordingContentAnalyzer: AudioContentAnalyzing, @unchecked Sendable {
    let sampleRate: Double
    let allowsUpwardGain = false
    private let lock = NSLock()
    private var storedAppendedFrameCount = 0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    var appendedFrameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedAppendedFrameCount
    }

    func append(
        input _: UnsafePointer<AudioBufferList>,
        frameCount: Int
    ) {
        lock.lock()
        storedAppendedFrameCount += frameCount
        lock.unlock()
    }
}
