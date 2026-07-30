// SPDX-License-Identifier: MPL-2.0

import CRNNoise
import Foundation

public enum RNNoiseModelError: Error, Equatable, LocalizedError {
    case resourceMissing
    case unreadableResource
    case checksumMismatch(expected: String, actual: String)
    case invalidModel

    public var errorDescription: String? {
        switch self {
        case .resourceMissing:
            return "The bundled RNNoise model is missing."
        case .unreadableResource:
            return "The bundled RNNoise model could not be read."
        case let .checksumMismatch(expected, actual):
            return "The RNNoise model checksum is invalid (expected \(expected), got \(actual))."
        case .invalidModel:
            return "RNNoise rejected the bundled model."
        }
    }
}

/// An immutable RNNoise model allocation that can be shared by analyzer states.
public final class RNNoiseModelResource: @unchecked Sendable {
    public static let bundledSHA256 = "1b99898350e75656c77d068162fea402afe51eff15dc751989b1e9f53b98bf91"

    let model: OpaquePointer
    private let storage: UnsafeMutableRawPointer
    private let storageSize: Int

    public static func bundled(bundle: Bundle? = nil) throws -> RNNoiseModelResource {
        let resourceBundle: Bundle
        if let bundle {
            resourceBundle = bundle
        } else if Bundle.main.bundleURL.pathExtension == "app" {
            guard let resourcesURL = Bundle.main.resourceURL,
                  let appResourceBundle = Bundle(
                      url: resourcesURL.appendingPathComponent("VolEq_VolEqSpeech.bundle")
                  ) else {
                throw RNNoiseModelError.resourceMissing
            }
            resourceBundle = appResourceBundle
        } else {
            resourceBundle = Bundle.module
        }
        guard let url = resourceBundle.url(forResource: "rnnoise-model", withExtension: "bin") else {
            throw RNNoiseModelError.resourceMissing
        }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            throw RNNoiseModelError.unreadableResource
        }
        return try RNNoiseModelResource(data: data, expectedSHA256: bundledSHA256)
    }

    public init(data: Data, expectedSHA256: String) throws {
        let actualSHA256 = SHA256.hexDigest(of: data)
        guard actualSHA256 == expectedSHA256.lowercased() else {
            throw RNNoiseModelError.checksumMismatch(expected: expectedSHA256, actual: actualSHA256)
        }
        guard !data.isEmpty, data.count <= Int(Int32.max) else {
            throw RNNoiseModelError.invalidModel
        }

        storageSize = data.count
        storage = UnsafeMutableRawPointer.allocate(byteCount: storageSize, alignment: 64)
        data.copyBytes(to: storage.assumingMemoryBound(to: UInt8.self), count: storageSize)
        guard let loadedModel = rnnoise_model_from_buffer(storage, Int32(storageSize)) else {
            storage.deallocate()
            throw RNNoiseModelError.invalidModel
        }
        model = loadedModel
    }

    deinit {
        rnnoise_model_free(model)
        storage.deallocate()
    }
}
