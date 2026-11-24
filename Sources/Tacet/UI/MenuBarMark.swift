import AppKit

@MainActor
enum MenuBarMark: CaseIterable {
    case ready
    case preparing
    case recording
    case processing
    case attention

    private static let images = Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.drawImage()) })

    var image: NSImage { Self.images[self]! }

    private var description: String {
        switch self {
        case .ready: return String(localized: "Tacet ready")
        case .preparing: return String(localized: "Tacet preparing microphone")
        case .recording: return String(localized: "Tacet recording")
        case .processing: return String(localized: "Tacet transcribing")
        case .attention: return String(localized: "Tacet needs attention")
        }
    }

    private var waveform: [CGFloat] {
        switch self {
        case .ready: return [2.8, 5.1, 3.3]
        case .preparing: return [1.2, 3.5, 1.2]
        case .recording: return [4.0, 7.1, 4.8]
        case .processing: return [1.2, 1.2, 1.2]
        case .attention: return [2.8, 5.1, 3.3]
        }
    }

    private func drawImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 21, height: 15), flipped: false) { _ in
            let outline = NSBezierPath(roundedRect: NSRect(x: 0.85, y: 2.25, width: 19.3, height: 10.5),
                                       xRadius: 5.25, yRadius: 5.25)
            NSColor.black.withAlphaComponent(self == .recording ? 1 : 0.76).setStroke()
            outline.lineWidth = 1.05
            outline.stroke()

            NSColor.black.setFill()
            if self == .attention {
                NSBezierPath(roundedRect: NSRect(x: 4.95, y: 7.3, width: 1.2, height: 3.05),
                             xRadius: 0.6, yRadius: 0.6).fill()
                NSBezierPath(ovalIn: NSRect(x: 4.9, y: 5.15, width: 1.3, height: 1.3)).fill()
            } else {
                let dot = NSBezierPath(ovalIn: NSRect(x: 4.15, y: 6.1, width: 2.8, height: 2.8))
                if self == .preparing {
                    NSColor.black.setStroke()
                    dot.lineWidth = 1
                    dot.stroke()
                } else {
                    dot.fill()
                }
            }

            // A template glyph follows the system menu bar contrast.
            // Шаблонний знак підлаштовується під контраст рядка меню.
            for (x, height) in zip([9.1, 12.2, 15.3], waveform) {
                let bar = NSRect(x: x, y: 7.5 - height / 2, width: 1.35, height: height)
                NSBezierPath(roundedRect: bar, xRadius: 0.675, yRadius: 0.675).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }
}
