#!/usr/bin/env swift
// Draws architecture-specific installer backgrounds.
// Малює тло інсталятора для відповідної архітектури.

import AppKit

let width = 1320
let height = 800

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: width,
    pixelsHigh: height,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else { fatalError("bitmap") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let bounds = CGRect(x: 0, y: 0, width: width, height: height)

// Background gradient.
let colors = [
    NSColor(red: 0.065, green: 0.15, blue: 0.23, alpha: 1).cgColor,
    NSColor(red: 0.03, green: 0.07, blue: 0.14, alpha: 1).cgColor,
]
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colors as CFArray,
                          locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: 0), options: [])

// Soft glows.
func glow(center: CGPoint, radius: CGFloat, color: NSColor) {
    let colors = [color.cgColor, color.withAlphaComponent(0).cgColor]
    if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
        ctx.drawRadialGradient(g,
                               startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: radius,
                               options: [])
    }
}
glow(center: CGPoint(x: 220, y: 640), radius: 420, color: NSColor(red: 0.12, green: 0.49, blue: 0.73, alpha: 0.24))
glow(center: CGPoint(x: 1120, y: 140), radius: 420, color: NSColor(red: 0.12, green: 0.64, blue: 0.68, alpha: 0.15))

// Arrow between the icons.
let arrowY = CGFloat(397)
let startX = CGFloat(519)
let endX = CGFloat(798)
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
ctx.setLineWidth(6)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: startX, y: arrowY))
ctx.addLine(to: CGPoint(x: endX - 44, y: arrowY))
ctx.strokePath()

ctx.setFillColor(NSColor.white.withAlphaComponent(0.22).cgColor)
ctx.move(to: CGPoint(x: endX, y: arrowY))
ctx.addLine(to: CGPoint(x: endX - 54, y: arrowY + 26))
ctx.addLine(to: CGPoint(x: endX - 54, y: arrowY - 26))
ctx.closePath()
ctx.fillPath()

// Text.
func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, y: CGFloat, alpha: CGFloat) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor.white.withAlphaComponent(alpha),
        .paragraphStyle: paragraph,
    ]
    let string = NSAttributedString(string: text, attributes: attributes)
    let rect = CGRect(x: 60, y: y, width: CGFloat(width) - 120, height: size * 1.4)
    string.draw(in: rect)
}

draw("Tacet", size: 64, weight: .semibold, y: 690, alpha: 0.92)
draw("Drag to Applications", size: 30, weight: .regular, y: 640, alpha: 0.45)
if !subtitle.isEmpty { draw(subtitle, size: 22, weight: .medium, y: 60, alpha: 0.28) }

NSGraphicsContext.restoreGraphicsState()

let output = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Assets/dmg-background-arm64.png"
let subtitle = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""

guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
try data.write(to: URL(fileURLWithPath: output))
print("wrote \(output) (\(width)x\(height))")
