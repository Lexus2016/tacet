import AppKit
import SwiftUI

final class HUDModel: ObservableObject {
    @Published var title: String = ""
    @Published var symbol: String = "mic.fill"
    @Published var level: Float = 0
    @Published var showsLevel: Bool = false
    @Published var isError: Bool = false
}

struct HUDView: View {
    @ObservedObject var model: HUDModel
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(model.isError ? Color.orange : Color.red)
                .symbolEffect(.pulse, isActive: model.showsLevel)

            Text(model.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

            if model.showsLevel {
                LevelBars(level: model.level)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        .fixedSize()
    }
}

private struct LevelBars: View {
    let level: Float

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                let threshold = Float(index + 1) / 5.0
                Capsule()
                    .fill(level >= threshold ? Color.red : Color.secondary.opacity(0.25))
                    .frame(width: 3, height: CGFloat(6 + index * 3))
            }
        }
        .frame(height: 20)
        .animation(.easeOut(duration: 0.08), value: level)
    }
}

@MainActor
final class HUDController {
    static let shared = HUDController()

    private let model = HUDModel()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    private init() {}

    func showRecording() {
        show(title: "Recording", symbol: "mic.fill", level: true, error: false, autoHide: nil)
    }

    func showProcessing() {
        show(title: "Transcribing…", symbol: "waveform", level: false, error: false, autoHide: nil)
    }

    func showMessage(_ text: String, isError: Bool) {
        show(title: text,
             symbol: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
             level: false,
             error: isError,
             autoHide: isError ? 2.6 : 1.4)
    }

    func updateLevel(_ level: Float) {
        guard model.showsLevel else { return }
        model.level = level
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
    }

    private func show(title: String, symbol: String, level: Bool, error: Bool, autoHide: TimeInterval?) {
        hideTask?.cancel()

        model.title = title
        model.symbol = symbol
        model.showsLevel = level
        model.isError = error
        if !level { model.level = 0 }

        let panel = ensurePanel()
        position(panel)
        panel.orderFrontRegardless()

        if let autoHide {
            hideTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(autoHide * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.panel?.orderOut(nil) }
            }
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false

        let hosting = NSHostingView(rootView: HUDView(model: model))
        hosting.setFrameSize(hosting.fittingSize)
        panel.contentView = hosting

        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - size.height - 24
        )
        panel.setFrameOrigin(origin)
    }
}
