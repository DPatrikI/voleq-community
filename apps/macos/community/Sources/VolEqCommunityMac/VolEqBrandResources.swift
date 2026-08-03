// SPDX-License-Identifier: MPL-2.0

import AppKit
import Foundation

struct VolEqBrandResources: Equatable {
    static let configurationFileName = "Info.plist"
    static let applicationIconKey = "CFBundleIconFile"
    static let menuBarTemplateKey = "VolEqMenuBarTemplateFile"

    struct Raster: Equatable {
        let fileName: String
        let pixelWidth: Int
        let pixelHeight: Int
    }

    let applicationIconFileName: String
    let menuBarTemplate: Raster

    init(infoDictionary: [String: Any]) throws {
        applicationIconFileName = try Self.requiredFileName(
            forKey: Self.applicationIconKey,
            expectedPathExtension: "icns",
            in: infoDictionary
        )
        menuBarTemplate = Raster(
            fileName: try Self.requiredFileName(
                forKey: Self.menuBarTemplateKey,
                expectedPathExtension: "png",
                in: infoDictionary
            ),
            pixelWidth: 256,
            pixelHeight: 256
        )
    }

    static func bundled() throws -> Self {
        guard let infoDictionary = Bundle.main.infoDictionary else {
            throw VolEqBrandResourceError.missingConfiguration(configurationFileName)
        }
        return try Self(infoDictionary: infoDictionary)
    }

    private static func requiredFileName(
        forKey key: String,
        expectedPathExtension: String,
        in infoDictionary: [String: Any]
    ) throws -> String {
        guard let value = infoDictionary[key] as? String, !value.isEmpty else {
            throw VolEqBrandResourceError.missingConfiguration(key)
        }
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let valueURL = URL(fileURLWithPath: value)
        guard value == trimmedValue,
              value != ".",
              value != "..",
              !value.contains("/"),
              !value.contains("\\"),
              !value.contains(":"),
              valueURL.pathExtension == expectedPathExtension
        else {
            throw VolEqBrandResourceError.invalidConfiguration(key)
        }
        return value
    }
}

enum VolEqBrandResourceError: LocalizedError {
    case missingConfiguration(String)
    case invalidConfiguration(String)
    case missing(String)
    case invalid(String)
    case unexpectedPixelSize(String, expectedWidth: Int, expectedHeight: Int, actualWidth: Int, actualHeight: Int)
    case missingVisibleArtwork(String)

    var errorDescription: String? {
        switch self {
        case let .missingConfiguration(key):
            "Missing branding configuration: \(key)"
        case let .invalidConfiguration(key):
            "Invalid branding resource filename for configuration: \(key)"
        case let .missing(name):
            "Missing packaged branding resource: \(name)"
        case let .invalid(name):
            "Could not decode packaged branding resource: \(name)"
        case let .unexpectedPixelSize(name, expectedWidth, expectedHeight, actualWidth, actualHeight):
            "Packaged branding resource \(name) is \(actualWidth)x\(actualHeight), expected \(expectedWidth)x\(expectedHeight) pixels"
        case let .missingVisibleArtwork(name):
            "Packaged branding resource has no visible artwork: \(name)"
        }
    }
}

@MainActor
enum VolEqBrand {
    static var applicationIcon: NSImage {
        NSApp.applicationIconImage ?? NSImage()
    }

    static let menuBarIcon: NSImage = {
        guard let resources = try? VolEqBrandResources.bundled(),
              let resourceDirectoryURL = Bundle.main.resourceURL,
              let icon = try? loadMenuBarIcon(
                  resources: resources,
                  resourceDirectoryURL: resourceDirectoryURL
              )
        else {
            let fallback = NSImage(
                systemSymbolName: "waveform",
                accessibilityDescription: "VolEq"
            ) ?? NSImage()
            fallback.isTemplate = true
            fallback.size = NSSize(width: 18, height: 18)
            return fallback
        }
        return icon
    }()

    static func verifyPackagedResources() throws {
        let resources = try VolEqBrandResources.bundled()
        guard let resourceDirectoryURL = Bundle.main.resourceURL else {
            throw VolEqBrandResourceError.missingConfiguration("Bundle resource URL")
        }

        _ = try loadMenuBarIcon(
            resources: resources,
            resourceDirectoryURL: resourceDirectoryURL
        )

        let iconURL = resourceDirectoryURL
            .appendingPathComponent(resources.applicationIconFileName)
        guard FileManager.default.fileExists(atPath: iconURL.path) else {
            throw VolEqBrandResourceError.missing(iconURL.lastPathComponent)
        }
        guard NSImage(contentsOf: iconURL) != nil else {
            throw VolEqBrandResourceError.invalid(iconURL.lastPathComponent)
        }
    }

    static func loadMenuBarIcon(
        resources: VolEqBrandResources,
        resourceDirectoryURL: URL
    ) throws -> NSImage {
        let resource = resources.menuBarTemplate
        let resourceURL = resourceDirectoryURL.appendingPathComponent(resource.fileName)
        try validateRasterResource(
            at: resourceURL,
            expectedPixels: (width: resource.pixelWidth, height: resource.pixelHeight)
        )
        guard let icon = NSImage(contentsOf: resourceURL) else {
            throw VolEqBrandResourceError.invalid(resource.fileName)
        }
        icon.isTemplate = true
        icon.size = NSSize(width: 18, height: 18)
        return icon
    }

    static func validateRasterResource(
        at url: URL,
        expectedPixels: (width: Int, height: Int)
    ) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VolEqBrandResourceError.missing(url.lastPathComponent)
        }
        guard let data = try? Data(contentsOf: url),
              let bitmap = NSBitmapImageRep(data: data)
        else {
            throw VolEqBrandResourceError.invalid(url.lastPathComponent)
        }
        guard bitmap.pixelsWide == expectedPixels.width,
              bitmap.pixelsHigh == expectedPixels.height
        else {
            throw VolEqBrandResourceError.unexpectedPixelSize(
                url.lastPathComponent,
                expectedWidth: expectedPixels.width,
                expectedHeight: expectedPixels.height,
                actualWidth: bitmap.pixelsWide,
                actualHeight: bitmap.pixelsHigh
            )
        }

        for y in 0 ..< bitmap.pixelsHigh {
            for x in 0 ..< bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.01 {
                return
            }
        }
        throw VolEqBrandResourceError.missingVisibleArtwork(url.lastPathComponent)
    }
}
