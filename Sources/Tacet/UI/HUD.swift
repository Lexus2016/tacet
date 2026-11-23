import AppKit
import SwiftUI

final class HUDModel: ObservableObject {
    @Published var title: String = ""
    @Published var subtitle: String?
    @Published var symbol: String = "mic.fill"
    @Published var level: Float = 0
    @Published var showsLevel: Bool = false
    @Published var isError: Bool = false
    @Published var tint: Color = Theme.danger
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HStack(spacing: 11) {
            badge

            VStack(alignment: .leading, spacing: 1) {
                Text(model.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if let subtitle = model.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }

            if model.showsLevel {
                LevelBars(level: model.level, tint: model.tint)
                    .padding(.leading, 2)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background {
            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.18).opacity(0.96), Color(white: 0.08).opacity(0.97)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.28), Color.white.opacity(0.04)],
                                startPoint: .top, endPoint: .bottom
                            ),
                            lineWidth: 0.9
                        )
                )
                .shadow(color: model.tint.opacity(0.35), radius: 18, x: 0, y: 6)
                .shadow(color: .black.opacity(0.45), radius: 10, x: 0, y: 4)
        }
        .fixedSize()
        .preferredColorScheme(.dark)
    }

    private var badge: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [model.tint.opacity(0.95), model.tint.opacity(0.62)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    Circle().stroke(Color.white.opacity(0.35), lineWidth: 0.8)
                )
                .shadow(color: model.tint.opacity(0.55), radius: 6, x: 0, y: 2)

            Image(systemName: model.symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 27, height: 27)
    }
}

private struct LevelBars: View {
    let level: Float
    let tint: Color

    private let heights: [CGFloat] = [7, 12, 17, 11, 6]

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(Array(heights.enumerated()), id: \.offset) { index, height in
                let threshold = Float(index + 1) / Float(heights.count)
                Capsule()
                    .fill(
                        level >= threshold
                            ? AnyShapeStyle(LinearGradient(colors: [tint, tint.opacity(0.6)],
                                                           startPoint: .top, endPoint: .bottom))
                            : AnyShapeStyle(Color.white.opacity(0.16))
                    )
                    .frame(width: 3, height: height)
            }
        }
        .frame(height: 18)
        .animation(.spring(response: 0.18, dampingFraction: 0.7), value: level)
    }
}

@MainActor
final class HUDController {
    static let shared = HUDController()

    private let model = HUDModel()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var startedAt: Date?

    private init() {}

    func showRecording() {
        startedAt = Date()
        model.subtitle = "0:00"
        show(title: "Recording", symbol: "mic.fill", tint: Theme.danger, level: true, error: false, autoHide: nil)
        startTicking()
    }

    func showProcessing() {
        stopTicking()
        startedAt = nil
        model.subtitle = nil
        show(title: "Transcribing…", symbol: "waveform", tint: Theme.accent, level: false, error: false, autoHide: nil)
    }

    func showMessage(_ text: String, isError: Bool) {
        stopTicking()
        startedAt = nil
        model.subtitle = nil
        show(title: text,
             symbol: isError ? "exclamationmark.triangle.fill" : "checkmark",
             tint: isError ? Theme.warning : Theme.success,
             level: false,
             error: isError,
             autoHide: isError ? 2.8 : 1.5)
    }

    func updateLevel(_ level: Float) {
        guard model.showsLevel else { return }
        model.level = level
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        stopTicking()
        startedAt = nil
        panel?.orderOut(nil)
    }

    private func show(title: String,
                      symbol: String,
                      tint: Color,
                      level: Bool,
                      error: Bool,
                      autoHide: TimeInterval?) {
        hideTask?.cancel()

        model.title = title
        model.symbol = symbol
        model.tint = tint
        model.showsLevel = level
        model.isError = error
        if !level { model.level = 0 }

        let panel = ensurePanel()
        resize(panel)
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

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self, let startedAt = self.startedAt else { return }
                let seconds = Int(Date().timeIntervalSince(startedAt))
                self.model.subtitle = String(format: "%d:%02d", seconds / 60, seconds % 60)
                if let panel = self.panel { self.resize(panel) }
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 46),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .darkAqua)

        let hosting = NSHostingView(rootView: HUDView(model: model))
        panel.contentView = hosting

        self.panel = panel
        return panel
    }

    private func resize(_ panel: NSPanel) {
        guard let hosting = panel.contentView else { return }
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize
        panel.setContentSize(NSSize(width: max(140, fitting.width), height: max(40, fitting.height)))
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - size.height - 26
        ))
    }
}
