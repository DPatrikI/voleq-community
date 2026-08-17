// SPDX-License-Identifier: MPL-2.0

import AVFoundation
import Foundation

private let sampleRate = 48_000.0
private let frequency = 523.25
private let amplitude: Float = 0.025

let duration = CommandLine.arguments.dropFirst().first
    .flatMap(Double.init) ?? 15
guard duration.isFinite, duration > 0, duration <= 60,
      let format = AVAudioFormat(
          standardFormatWithSampleRate: sampleRate,
          channels: 2
      )
else {
    FileHandle.standardError.write(Data("Invalid test-source configuration.\n".utf8))
    exit(EXIT_FAILURE)
}

let engine = AVAudioEngine()
var phase = 0.0
let phaseIncrement = 2 * Double.pi * frequency / sampleRate
let source = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
    let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
    var frame = 0
    while frame < Int(frameCount) {
        let sample = amplitude * Float(sin(phase))
        phase += phaseIncrement
        if phase >= 2 * Double.pi { phase -= 2 * Double.pi }
        var bufferIndex = 0
        while bufferIndex < buffers.count {
            let buffer = buffers[bufferIndex]
            if let data = buffer.mData {
                let samples = data.assumingMemoryBound(to: Float.self)
                let channels = max(Int(buffer.mNumberChannels), 1)
                var channel = 0
                while channel < channels {
                    samples[frame * channels + channel] = sample
                    channel += 1
                }
            }
            bufferIndex += 1
        }
        frame += 1
    }
    return noErr
}

engine.attach(source)
engine.connect(source, to: engine.mainMixerNode, format: format)
do {
    try engine.start()
    Thread.sleep(forTimeInterval: duration)
    engine.stop()
} catch {
    FileHandle.standardError.write(Data("Test source failed: \(error.localizedDescription)\n".utf8))
    exit(EXIT_FAILURE)
}
