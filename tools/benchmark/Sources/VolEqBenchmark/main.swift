// SPDX-License-Identifier: MPL-2.0

import Darwin
import Foundation
import VolEqDSP
import VolEqSpeech

precondition(
    !_isDebugAssertConfiguration(),
    "VolEqBenchmark must be built in release mode"
)

private final class BenchmarkAuthority: UpwardGainAuthorizing, @unchecked Sendable {
    let allowsUpwardGain = true
}

private func threadCPUSeconds() -> Double {
    var timestamp = timespec()
    precondition(clock_gettime(CLOCK_THREAD_CPUTIME_ID, &timestamp) == 0)
    return Double(timestamp.tv_sec) + Double(timestamp.tv_nsec) / 1_000_000_000
}

private func hardwareModel() -> String {
    var size = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
        return "unknown"
    }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else {
        return "unknown"
    }
    return String(cString: bytes)
}

let sampleRate = 48_000
let representedSeconds = 60
let model = try RNNoiseModelResource.bundled()
let speech = try RNNoiseStereoProcessor(sampleRate: Double(sampleRate), model: model)
guard speech.sourceBlockFrameCount == 480,
      speech.decisionLatencyFrameCount == 480,
      speech.processingLatencyFrameCount == 1_440,
      speech.inputResamplerLatencyFrameCount == 0,
      speech.outputResamplerLatencyFrameCount == 0 else {
    fputs("benchmark failed: unexpected 48 kHz RNNoise workload or latency\n", stderr)
    exit(2)
}
let processor = try DynamicsProcessor(
    sampleRate: Double(sampleRate),
    stereoSpeechProcessor: speech,
    upwardGainAuthorizer: BenchmarkAuthority()
)
let fixtureFrameCount = sampleRate / 10
var fixtureLeft = [Float](repeating: 0, count: fixtureFrameCount)
var fixtureRight = [Float](repeating: 0, count: fixtureFrameCount)
for frame in 0..<fixtureFrameCount {
    let voiced = Float(
        sin(2 * Double.pi * 180 * Double(frame) / Double(sampleRate))
            + 0.45 * sin(2 * Double.pi * 360 * Double(frame) / Double(sampleRate))
    ) * 0.045
    let noise = Float((frame * 37) % 257 - 128) / 128 * 0.012
    fixtureLeft[frame] = voiced + noise
    fixtureRight[frame] = voiced * 0.92 - noise * 0.8
}

for frame in 0..<(sampleRate * 2) {
    if frame.isMultiple(of: 512) { processor.beginAudioBuffer() }
    let fixture = frame % fixtureFrameCount
    _ = processor.processFrame(left: fixtureLeft[fixture], right: fixtureRight[fixture])
}
processor.reset()
for frame in 0..<(sampleRate * 2) {
    if frame.isMultiple(of: 512) { processor.beginAudioBuffer() }
    let fixture = frame % fixtureFrameCount
    _ = processor.processFrame(left: fixtureLeft[fixture], right: fixtureRight[fixture])
}

let startingInferencePairCount = speech.completedOptimizedInferencePairCount
let start = threadCPUSeconds()
var outputChecksum: Float = 0
for frame in 0..<(sampleRate * representedSeconds) {
    if frame.isMultiple(of: 512) { processor.beginAudioBuffer() }
    let fixture = frame % fixtureFrameCount
    let output = processor.processFrame(left: fixtureLeft[fixture], right: fixtureRight[fixture])
    if frame.isMultiple(of: 4_096) {
        outputChecksum += abs(output.left) + abs(output.right)
    }
}
let cpuSeconds = threadCPUSeconds() - start
let cpuPercent = cpuSeconds / Double(representedSeconds) * 100
let completedInferencePairCount = speech.completedOptimizedInferencePairCount
    - startingInferencePairCount
guard !processor.consumeProcessingFailure(),
      cpuPercent.isFinite,
      outputChecksum.isFinite,
      outputChecksum > 0,
      completedInferencePairCount == representedSeconds * 100 else {
    fputs("benchmark failed: processing did not remain finite\n", stderr)
    exit(1)
}

print("VolEq mild-noise-suppression CPU benchmark")
print("Hardware: \(hardwareModel())")
print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
print("Format: 48 kHz stereo, release build")
print("Fixture: two-tone voiced signal with deterministic stationary noise")
print("Represented audio: \(representedSeconds) seconds")
print(String(format: "Thread CPU: %.3f seconds (%.2f%% of one core)", cpuSeconds, cpuPercent))
guard cpuPercent <= 5 else {
    fputs("benchmark failed: CPU target is no more than 5%\n", stderr)
    exit(1)
}
