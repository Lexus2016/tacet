#!/usr/bin/env swift
import AppKit
import Foundation

let sourceURL = URL(fileURLWithPath: "Assets/icon-source.png")
let iconset = URL(fileURLWithPath: "Sources/Tacet/Resources/Assets.xcassets/AppIcon.appiconset")
guard let source = NSImage(contentsOf: sourceURL) else { fatalError("Invalid icon source") }

// Keep the bevel and alpha in the source art, with optical room at AppKit sizes.
// Зберігаємо скляну грань і прозорість, залишаючи поля для розмірів AppKit.
func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context

    let bounds = CGRect(x: 0, y: 0, width: size, height: size)
    let graphics = context.cgContext
    graphics.clear(bounds)
    let inset = CGFloat(size) * (size <= 32 ? 0.035 : 0.073)
    let artwork = bounds.insetBy(dx: inset, dy: inset)
    if size == 16 {
        drawSmallIcon(in: artwork, graphics: graphics)
    } else {
        let edge = artwork.insetBy(dx: artwork.width * 0.028, dy: artwork.height * 0.038)
        let radius = edge.width * 0.249
        graphics.addPath(CGPath(roundedRect: edge, cornerWidth: radius, cornerHeight: radius, transform: nil))
        graphics.clip()
        source.draw(in: artwork, from: .zero, operation: .sourceOver,
                    fraction: 1, respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }
    return rep.representation(using: .png, properties: [:])!
}

// At 16 pixels, the waveform needs three clearly separated strokes.
// На 16 пікселях для хвилі потрібні три чітко розділені штрихи.
func drawSmallIcon(in bounds: CGRect, graphics: CGContext) {
    let tile = bounds.insetBy(dx: 0.55, dy: 0.55)
    graphics.setFillColor(CGColor(red: 0.12, green: 0.18, blue: 0.27, alpha: 1))
    graphics.addPath(CGPath(roundedRect: tile, cornerWidth: 3.4, cornerHeight: 3.4, transform: nil))
    graphics.fillPath()

    let capsule = CGRect(x: 2.3, y: 4.95, width: 11.4, height: 6.1)
    graphics.setStrokeColor(CGColor(red: 0.66, green: 0.76, blue: 0.88, alpha: 0.85))
    graphics.setLineWidth(0.6)
    graphics.addPath(CGPath(roundedRect: capsule, cornerWidth: 3, cornerHeight: 3, transform: nil))
    graphics.strokePath()

    graphics.setFillColor(CGColor(red: 0.35, green: 0.69, blue: 1, alpha: 1))
    graphics.fillEllipse(in: CGRect(x: 3.6, y: 6.3, width: 3.2, height: 3.4))
    graphics.setStrokeColor(CGColor(red: 0.84, green: 0.90, blue: 0.95, alpha: 1))
    graphics.setLineWidth(1)
    graphics.setLineCap(.round)
    for (x, height) in [(8.5, 1.4), (10.5, 3.1), (12.1, 1.4)] {
        graphics.move(to: CGPoint(x: x, y: 8 - height / 2))
        graphics.addLine(to: CGPoint(x: x, y: 8 + height / 2))
    }
    graphics.strokePath()
}

func renderIOSIcon() -> Data {
    let size = 1024
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let graphics = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                             bytesPerRow: 0, space: colorSpace,
                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let context = NSGraphicsContext(cgContext: graphics, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context

    // Fill the square because iOS applies the outer mask at display time.
    // Заповнюємо квадрат, бо зовнішню маску під час показу накладає iOS.
    let bounds = CGRect(x: 0, y: 0, width: size, height: size)
    let colors = [
        CGColor(red: 0.32, green: 0.40, blue: 0.52, alpha: 1),
        CGColor(red: 0.09, green: 0.14, blue: 0.22, alpha: 1),
    ]
    let background = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: [0, 1])!
    graphics.drawLinearGradient(background, start: CGPoint(x: bounds.midX, y: bounds.maxY),
                                end: CGPoint(x: bounds.midX, y: bounds.minY), options: [])
    let artwork = bounds.insetBy(dx: -bounds.width * 0.025, dy: -bounds.height * 0.025)
    let edge = artwork.insetBy(dx: artwork.width * 0.02, dy: artwork.height * 0.028)
    let radius = edge.width * 0.249
    graphics.addPath(CGPath(roundedRect: edge, cornerWidth: radius, cornerHeight: radius, transform: nil))
    graphics.clip()
    source.draw(in: artwork, from: .zero, operation: .sourceOver,
                fraction: 1, respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    return NSBitmapImageRep(cgImage: graphics.makeImage()!).representation(using: .png, properties: [:])!
}

if CommandLine.arguments.contains("--ios") {
    let output = URL(fileURLWithPath: "ios/App/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
    try renderIOSIcon().write(to: output, options: .atomic)
} else {
    for size in [16, 32, 128, 256, 512] {
        for scale in 1...2 {
            let suffix = scale == 1 ? "" : "@2x"
            let name = "icon_\(size)x\(size)\(suffix).png"
            try render(size: size * scale).write(to: iconset.appendingPathComponent(name), options: .atomic)
        }
    }
}
