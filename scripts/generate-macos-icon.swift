#!/usr/bin/env swift
// SPDX-License-Identifier: MPL-2.0

import AppKit
import Foundation

enum IconGenerationError: Error, CustomStringConvertible {
    case unreadableImage(URL)
    case missingVisibleArtwork(URL)
    case renderingFailed(Int)
    case iconutilFailed(Int32)
    case generatedAssetDrift(URL)
    case missingResourceDefinition(String)
    case invalidResourceDefinition(String)
    case invalidConfiguration(URL)

    var description: String {
        switch self {
        case let .unreadableImage(url):
            "Could not read image at \(url.path)"
        case let .missingVisibleArtwork(url):
            "No visible artwork was found at \(url.path)"
        case let .renderingFailed(size):
            "Could not render the \(size)x\(size) icon"
        case let .iconutilFailed(status):
            "iconutil failed with status \(status)"
        case let .generatedAssetDrift(url):
            "Generated branding differs from the committed asset at \(url.path). Run scripts/generate-macos-icon.swift and review the result."
        case let .missingResourceDefinition(key):
            "Info.plist does not define a branding resource for \(key)"
        case let .invalidResourceDefinition(key):
            "Info.plist defines an invalid branding resource filename for \(key)"
        case let .invalidConfiguration(url):
            "Could not read branding configuration at \(url.path)"
        }
    }
}

struct BrandingOutputs {
    static let applicationIconKey = "CFBundleIconFile"
    static let menuBarTemplateKey = "VolEqMenuBarTemplateFile"

    let applicationIconFileName: String
    let menuBarTemplateFileName: String

    init(infoPlistURL: URL) throws {
        let data = try Data(contentsOf: infoPlistURL)
        guard let dictionary = try PropertyListSerialization.propertyList(
            from: data,
            format: nil
        ) as? [String: Any] else {
            throw IconGenerationError.invalidConfiguration(infoPlistURL)
        }
        applicationIconFileName = try Self.requiredFileName(
            forKey: Self.applicationIconKey,
            expectedPathExtension: "icns",
            in: dictionary
        )
        menuBarTemplateFileName = try Self.requiredFileName(
            forKey: Self.menuBarTemplateKey,
            expectedPathExtension: "png",
            in: dictionary
        )
    }

    private static func requiredFileName(
        forKey key: String,
        expectedPathExtension: String,
        in dictionary: [String: Any]
    ) throws -> String {
        guard let value = dictionary[key] as? String, !value.isEmpty else {
            throw IconGenerationError.missingResourceDefinition(key)
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
            throw IconGenerationError.invalidResourceDefinition(key)
        }
        return value
    }
}

let scriptURL = URL(fileURLWithPath: #filePath).standardizedFileURL
let repositoryRoot = scriptURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let resources = repositoryRoot
    .appendingPathComponent("apps/macos/community/Resources", isDirectory: true)
let infoPlistURL = resources.appendingPathComponent("Info.plist")
let sourceDirectory = resources.appendingPathComponent("AppIconSource", isDirectory: true)
let backgroundURL = sourceDirectory.appendingPathComponent("premium-background.png")
let foregroundURL = sourceDirectory.appendingPathComponent("voleq-mark.png")
let checkMode = CommandLine.arguments.dropFirst().contains("--check")
let checkDirectory = repositoryRoot
    .appendingPathComponent(".build/VolEqIconCheck", isDirectory: true)
let outputDirectory = checkMode ? checkDirectory : resources

func loadImage(at url: URL) throws -> NSImage {
    guard let image = NSImage(contentsOf: url) else {
        throw IconGenerationError.unreadableImage(url)
    }
    return image
}

func visibleBounds(of image: NSImage, sourceURL: URL) throws -> NSRect {
    guard let data = try? Data(contentsOf: sourceURL),
          let bitmap = NSBitmapImageRep(data: data)
    else {
        throw IconGenerationError.unreadableImage(sourceURL)
    }

    var minimumX = bitmap.pixelsWide
    var minimumY = bitmap.pixelsHigh
    var maximumX = -1
    var maximumY = -1

    for y in 0 ..< bitmap.pixelsHigh {
        for x in 0 ..< bitmap.pixelsWide {
            guard (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.01 else {
                continue
            }
            minimumX = min(minimumX, x)
            minimumY = min(minimumY, y)
            maximumX = max(maximumX, x)
            maximumY = max(maximumY, y)
        }
    }

    guard maximumX >= minimumX, maximumY >= minimumY else {
        throw IconGenerationError.missingVisibleArtwork(sourceURL)
    }

    let scaleX = image.size.width / CGFloat(bitmap.pixelsWide)
    let scaleY = image.size.height / CGFloat(bitmap.pixelsHigh)
    return NSRect(
        x: CGFloat(minimumX) * scaleX,
        y: CGFloat(minimumY) * scaleY,
        width: CGFloat(maximumX - minimumX + 1) * scaleX,
        height: CGFloat(maximumY - minimumY + 1) * scaleY
    )
}

func renderIcon(
    size: Int,
    background: NSImage,
    foreground: NSImage,
    foregroundSourceRect: NSRect
) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw IconGenerationError.renderingFailed(size)
    }

    let side = CGFloat(size)
    bitmap.size = NSSize(width: side, height: side)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: side, height: side).fill()

    let container = NSRect(
        x: side * 0.0625,
        y: side * 0.0625,
        width: side * 0.875,
        height: side * 0.875
    )
    let containerPath = NSBezierPath(
        roundedRect: container,
        xRadius: side * 0.195,
        yRadius: side * 0.195
    )
    containerPath.addClip()
    background.draw(
        in: container,
        from: NSRect(origin: .zero, size: background.size),
        operation: .copy,
        fraction: 1,
        respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high]
    )

    let markWidth = side * 0.61
    let markHeight = markWidth * foregroundSourceRect.height / foregroundSourceRect.width
    let markFrame = NSRect(
        x: (side - markWidth) / 2,
        y: (side - markHeight) / 2,
        width: markWidth,
        height: markHeight
    )
    foreground.draw(
        in: markFrame,
        from: foregroundSourceRect,
        operation: .sourceOver,
        fraction: 1,
        respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high]
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw IconGenerationError.renderingFailed(size)
    }
    return data
}

func renderMenuBarTemplate(
    size: Int,
    foreground: NSImage,
    foregroundSourceRect: NSRect
) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw IconGenerationError.renderingFailed(size)
    }

    let side = CGFloat(size)
    bitmap.size = NSSize(width: side, height: side)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: side, height: side).fill()

    let markWidth = side * 0.84
    let markHeight = markWidth * foregroundSourceRect.height / foregroundSourceRect.width
    let markFrame = NSRect(
        x: (side - markWidth) / 2,
        y: (side - markHeight) / 2,
        width: markWidth,
        height: markHeight
    )
    foreground.draw(
        in: markFrame,
        from: foregroundSourceRect,
        operation: .sourceOver,
        fraction: 1,
        respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high]
    )
    context.cgContext.setBlendMode(.sourceIn)
    context.cgContext.setFillColor(NSColor.black.cgColor)
    context.cgContext.fill(NSRect(x: 0, y: 0, width: side, height: side))
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw IconGenerationError.renderingFailed(size)
    }
    return data
}

let iconFiles: [(name: String, size: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

do {
    let outputs = try BrandingOutputs(infoPlistURL: infoPlistURL)
    let applicationIconStem = URL(fileURLWithPath: outputs.applicationIconFileName)
        .deletingPathExtension()
        .lastPathComponent
    let iconsetURL = checkMode
        ? checkDirectory.appendingPathComponent("\(applicationIconStem).iconset", isDirectory: true)
        : repositoryRoot.appendingPathComponent(".build/\(applicationIconStem).iconset", isDirectory: true)
    let outputURL = outputDirectory
        .appendingPathComponent(outputs.applicationIconFileName)
    let menuBarOutputURL = outputDirectory
        .appendingPathComponent(outputs.menuBarTemplateFileName)
    let background = try loadImage(at: backgroundURL)
    let foreground = try loadImage(at: foregroundURL)
    let foregroundSourceRect = try visibleBounds(of: foreground, sourceURL: foregroundURL)
    let fileManager = FileManager.default

    if checkMode {
        try? fileManager.removeItem(at: checkDirectory)
        try fileManager.createDirectory(at: checkDirectory, withIntermediateDirectories: true)
    }
    try? fileManager.removeItem(at: iconsetURL)
    try fileManager.createDirectory(
        at: iconsetURL,
        withIntermediateDirectories: true
    )

    for iconFile in iconFiles {
        let data = try renderIcon(
            size: iconFile.size,
            background: background,
            foreground: foreground,
            foregroundSourceRect: foregroundSourceRect
        )
        try data.write(to: iconsetURL.appendingPathComponent(iconFile.name), options: .atomic)
    }

    let menuBarData = try renderMenuBarTemplate(
        size: 256,
        foreground: foreground,
        foregroundSourceRect: foregroundSourceRect
    )
    try menuBarData.write(to: menuBarOutputURL, options: .atomic)

    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = [
        "--convert", "icns",
        "--output", outputURL.path,
        iconsetURL.path,
    ]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else {
        throw IconGenerationError.iconutilFailed(iconutil.terminationStatus)
    }

    if checkMode {
        for generatedURL in [outputURL, menuBarOutputURL] {
            let committedURL = resources
                .appendingPathComponent(generatedURL.lastPathComponent)
            guard fileManager.fileExists(atPath: committedURL.path),
                  try Data(contentsOf: generatedURL) == Data(contentsOf: committedURL)
            else {
                throw IconGenerationError.generatedAssetDrift(committedURL)
            }
        }
        try fileManager.removeItem(at: checkDirectory)
        print("[ok] generated VolEq branding matches committed resources")
    } else {
        try? fileManager.removeItem(at: iconsetURL)
        print(outputURL.path)
        print(menuBarOutputURL.path)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
