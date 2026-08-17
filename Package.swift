// swift-tools-version: 5.10
// SPDX-License-Identifier: MPL-2.0

import PackageDescription

let package = Package(
    name: "VolEq",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VolEqCore", targets: ["VolEqCore"]),
        .library(name: "VolEqDSP", targets: ["VolEqDSP"]),
        .library(name: "VolEqSpeech", targets: ["VolEqSpeech"]),
        .library(name: "VolEqMacAudio", targets: ["VolEqMacAudio"]),
        .executable(name: "VolEqCommunityMac", targets: ["VolEqCommunityMac"]),
        .executable(
            name: "VolEqLivenessTestSource",
            targets: ["VolEqLivenessTestSource"]
        )
    ],
    targets: [
        .target(
            name: "VolEqCore",
            path: "packages/core/swift/Sources/VolEqCore"
        ),
        .target(
            name: "CRNNoise",
            path: "third_party/rnnoise",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("src"),
                .define("USE_WEIGHTS_FILE"),
                .define("RNNOISE_BUILD")
            ],
            linkerSettings: [.linkedLibrary("m")]
        ),
        .target(
            name: "CSpeexResampler",
            path: "third_party/speexdsp",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("src"),
                .define("OUTSIDE_SPEEX"),
                .define("FLOATING_POINT"),
                .define("RANDOM_PREFIX", to: "voleq_speex")
            ],
            linkerSettings: [.linkedLibrary("m")]
        ),
        .target(
            name: "VolEqSpeech",
            dependencies: ["CRNNoise", "CSpeexResampler"],
            path: "packages/speech/swift/Sources/VolEqSpeech",
            resources: [.process("Resources")]
        ),
        .target(
            name: "VolEqDSP",
            dependencies: ["VolEqCore", "VolEqSpeech"],
            path: "packages/dsp/swift/Sources/VolEqDSP"
        ),
        .target(
            name: "CVolEqRealtime",
            path: "platforms/macos/Sources/CVolEqRealtime",
            publicHeadersPath: "include"
        ),
        .target(
            name: "CVolEqRealtimeTestSupport",
            path: "platforms/macos/Tests/CVolEqRealtimeTestSupport",
            publicHeadersPath: "include"
        ),
        .target(
            name: "VolEqMacAudio",
            dependencies: ["VolEqCore", "VolEqDSP", "VolEqSpeech", "CVolEqRealtime"],
            path: "platforms/macos/Sources/VolEqMacAudio"
        ),
        .executableTarget(
            name: "VolEqCommunityMac",
            dependencies: ["VolEqMacAudio", "VolEqSpeech"],
            path: "apps/macos/community/Sources/VolEqCommunityMac"
        ),
        .executableTarget(
            name: "VolEqLivenessTestSource",
            path: "tools/audio-liveness-test-source/Sources"
        ),
        .executableTarget(
            name: "VolEqBenchmark",
            dependencies: ["VolEqCore", "VolEqDSP", "VolEqSpeech"],
            path: "tools/benchmark/Sources/VolEqBenchmark"
        ),
        .testTarget(
            name: "VolEqDSPTests",
            dependencies: ["VolEqCore", "VolEqDSP", "VolEqSpeech"],
            path: "packages/dsp/swift/Tests/VolEqDSPTests"
        ),
        .testTarget(
            name: "VolEqSpeechTests",
            dependencies: ["VolEqSpeech"],
            path: "packages/speech/swift/Tests/VolEqSpeechTests"
        ),
        .testTarget(
            name: "VolEqMacAudioTests",
            dependencies: [
                "VolEqCore",
                "VolEqDSP",
                "VolEqSpeech",
                "VolEqMacAudio",
                "CVolEqRealtime",
                "CVolEqRealtimeTestSupport"
            ],
            path: "platforms/macos/Tests/VolEqMacAudioTests"
        ),
        .testTarget(
            name: "VolEqCommunityMacTests",
            dependencies: ["VolEqCommunityMac"],
            path: "apps/macos/community/Tests/VolEqCommunityMacTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
