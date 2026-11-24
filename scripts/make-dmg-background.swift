#!/usr/bin/env swift
// Draws architecture-specific installer backgrounds.
// Малює тло інсталятора для відповідної архітектури.

import AppKit

let width = 660
let height = 400
let output = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Assets/dmg-background-arm64.png"
let subtitle = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""

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

// Keep Finder's dark icon labels readable against the background.
// Світле тло зберігає читабельність темних підписів Finder.
let colors = [
    NSColor(red: 0.95, green: 0.97, blue: 0.99, alpha: 1).cgColor,
    NSColor(red: 0.75, green: 0.84, blue: 0.91, alpha: 1).cgColor,
]
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colors as CFArray,
                          locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: 0), options: [])

// Soft glows. / М’яке підсвічення.
func glow(center: CGPoint, radius: CGFloat, color: NSColor) {
    let colors = [color.cgColor, color.withAlphaComponent(0).cgColor]
    if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
        ctx.drawRadialGradient(g,
                               startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: radius,
                               options: [])
    }
}
glow(center: CGPoint(x: 110, y: 320), radius: 210, color: NSColor.white.withAlphaComponent(0.8))
glow(center: CGPoint(x: 560, y: 70), radius: 210, color: NSColor(red: 0.39, green: 0.62, blue: 0.81, alpha: 0.23))

// Arrow between the icons. / Стрілка між іконками.
let ink = NSColor(red: 0.09, green: 0.17, blue: 0.28, alpha: 1)
let arrowY = CGFloat(200)
let startX = CGFloat(285)
let endX = CGFloat(375)
ctx.setStrokeColor(ink.withAlphaComponent(0.55).cgColor)
ctx.setLineWidth(3)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.move(to: CGPoint(x: startX, y: arrowY))
ctx.addLine(to: CGPoint(x: endX, y: arrowY))
ctx.move(to: CGPoint(x: endX - 10, y: arrowY + 10))
ctx.addLine(to: CGPoint(x: endX, y: arrowY))
ctx.addLine(to: CGPoint(x: endX - 10, y: arrowY - 10))
ctx.strokePath()

// Text. / Текст.
func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, y: CGFloat, alpha: CGFloat) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: ink.withAlphaComponent(alpha),
        .paragraphStyle: paragraph,
    ]
    let string = NSAttributedString(string: text, attributes: attributes)
    let rect = CGRect(x: 30, y: y, width: CGFloat(width) - 60, height: size * 1.4)
    string.draw(in: rect)
}

draw("Tacet", size: 38, weight: .semibold, y: 331, alpha: 1)
draw("Drag Tacet to Applications", size: 18, weight: .medium, y: 304, alpha: 0.88)
if !subtitle.isEmpty { draw(subtitle, size: 13, weight: .medium, y: 280, alpha: 0.72) }

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
try data.write(to: URL(fileURLWithPath: output))
print("wrote \(output) (\(width)x\(height))")
