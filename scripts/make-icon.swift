#!/usr/bin/env swift
// Builds Assets.xcassets/AppIcon.appiconset from Assets/icon-source.png.
// The macOS icon grid wants the artwork inset to 824/1024 of the canvas with a
// 185/824 corner radius; the generated source is nearly full-bleed, so the
// corners are masked away instead of left white.

import AppKit
import Foundation

let root = FileManager.default.currentDirectoryPath
let sourcePath = "\(root)/Assets/icon-source.png"
let outDirectory = "\(root)/Sources/Tacet/Resources/Assets.xcassets/AppIcon.appiconset"

guard let source = NSImage(contentsOfFile: sourcePath) else {
    fatalError("Missing \(sourcePath)")
}
try? FileManager.default.createDirectory(atPath: outDirectory, withIntermediateDirectories: true)

/// Apple's macOS grid ratios.
let insetRatio = 100.0 / 1024.0
let cornerRatio = 185.0 / 824.0

func render(size: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
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
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = context

    let cg = context.cgContext
    cg.clear(CGRect(x: 0, y: 0, width: size, height: size))
    cg.interpolationQuality = .high

    let inset = CGFloat(size) * insetRatio
    let side = CGFloat(size) - inset * 2
    let rect = CGRect(x: inset, y: inset, width: side, height: side)
    let radius = side * cornerRatio
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    cg.addPath(path)
    cg.clip()

    source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high.rawValue])

    return rep.representation(using: .png, properties: [:])
}

let variants: [(String, Int)] = [
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

for (name, size) in variants {
    guard let data = render(size: size) else {
        fatalError("Could not render \(name)")
    }
    try data.write(to: URL(fileURLWithPath: "\(outDirectory)/\(name)"))
}

let contents = """
{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""

try contents.write(toFile: "\(outDirectory)/Contents.json", atomically: true, encoding: .utf8)
print("Wrote \(variants.count) icon variants to \(outDirectory)")
