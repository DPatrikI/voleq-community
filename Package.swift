// swift-tools-version: 5.10
// SPDX-License-Identifier: MPL-2.0

import PackageDescription

let package = Package(
    name: "VolEq",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VolEqCore", targets: ["VolEqCore"]),
        .library(name: "VolEqDSP", targets: ["VolEqDSP"]),
        .library(name: "VolEqMacAudio", targets: ["VolEqMacAudio"]),
        .executable(name: "VolEqCommunityMac", targets: ["VolEqCommunityMac"])
    ],
    targets: [
        .target(
            name: "VolEqCore",
            path: "packages/core/swift/Sources/VolEqCore"
        ),
        .target(
            name: "VolEqDSP",
            dependencies: ["VolEqCore"],
            path: "packages/dsp/swift/Sources/VolEqDSP"
        ),
        .target(
            name: "VolEqMacAudio",
            dependencies: ["VolEqCore", "VolEqDSP"],
            path: "platforms/macos/Sources/VolEqMacAudio"
        ),
        .executableTarget(
            name: "VolEqCommunityMac",
            dependencies: ["VolEqMacAudio"],
            path: "apps/macos/community/Sources/VolEqCommunityMac"
        ),
        .testTarget(
            name: "VolEqDSPTests",
            dependencies: ["VolEqCore", "VolEqDSP"],
            path: "packages/dsp/swift/Tests/VolEqDSPTests"
        ),
        .testTarget(
            name: "VolEqMacAudioTests",
            dependencies: ["VolEqMacAudio"],
            path: "platforms/macos/Tests/VolEqMacAudioTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
