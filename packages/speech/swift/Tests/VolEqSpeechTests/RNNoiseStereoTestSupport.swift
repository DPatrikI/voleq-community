// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import VolEqSpeech

enum RNNoiseStereoTestSupport {
    static let model = try! RNNoiseModelResource.bundled()

    static func mixSnapshot(_ value: UInt64, into hash: inout UInt64) {
        for shift in stride(from: 0, through: 56, by: 8) {
            hash ^= (value >> UInt64(shift)) & 0xff
            hash &*= 1_099_511_628_211
        }
    }
}
