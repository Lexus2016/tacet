import AppKit
import SwiftUI

enum IndicatorStyle: String, CaseIterable, Identifiable {
    case island
    case notch
    case overlay
    case minimal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .island: return "Tacet island"
        case .notch: return "Notch"
        case .overlay: return "Overlay"
        case .minimal: return "Minimal"
        }
    }

    var detail: String {
        switch self {
        case .island: return "Glass pill above the Dock"
        case .notch: return "Black shape hugging the top edge"
        case .overlay: return "Floating pill under the menu bar"
        case .minimal: return "Small dot with a waveform, top right"
        }
    }
}

final class HUDModel: ObservableObject {
    @Published var title: String = ""
    @Published var subtitle: String?
    @Published var symbol: String = "mic.fill"
    @Published var level: Float = 0
    @Published var showsLevel: Bool = false
    @Published var isError: Bool = false
    @Published var tint: Color = Theme.danger
    @Published var style: IndicatorStyle = .island
}

// MARK: - Waveform

/// Ported from TypeWhisper's AudioWaveformBarModel: center-weighted bars, a
/// per-bar drift so they keep moving while the level holds, and attack/release
/// smoothing so they do not twitch between level updates.
struct IndicatorWaveform: View {
    let level: Float
    var barCount: Int = 5
    var height: CGFloat = 16
    var tint: Color = .white
    var barWidth: CGFloat = 3

    @State private var heights: [CGFloat] = []
    @State private var lastTick: TimeInterval = 0

    private let timer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(tint)
                    .frame(width: barWidth,
                           height: max(2, heights.indices.contains(index) ? heights[index] * height : 2))
            }
        }
        .frame(height: height)
        .onReceive(timer) { advance($0) }
        .onAppear {
            if heights.count != barCount {
                heights = Array(repeating: 0, count: barCount)
            }
        }
    }

    private func advance(_ now: Date) {
        let time = now.timeIntervalSinceReferenceDate
        let elapsed = lastTick == 0 ? 1.0 / 30.0 : min(0.1, max(0.001, time - lastTick))
        lastTick = time

        if heights.count != barCount {
            heights = Array(repeating: 0, count: barCount)
        }

        let level = CGFloat(min(1, max(0, self.level)))
        for index in 0..<barCount {
            let position = (Double(index) + 0.5) / Double(barCount)
            let shape = 0.55 + 0.45 * CGFloat(sin(.pi * position))
            let rate = 2.2 + 0.65 * Double(index)
            let phase = Double(index) * 2.1
            let drift = 0.8 + 0.2 * CGFloat(sin(time * rate + phase))
            let target = level * shape * drift
            let tau: CGFloat = target > heights[index] ? 0.04 : 0.16
            heights[index] += (target - heights[index]) * CGFloat(1 - exp(-elapsed / Double(tau)))
        }
    }
}

// MARK: - Shapes

/// Straight top edge and rounded bottom ears, like the MacBook notch.
struct NotchShape: Shape {
    var bottomCornerRadius: CGFloat = 14

    var animatableData: CGFloat {
        get { bottomCornerRadius }
        set { bottomCornerRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomCornerRadius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - bottomCornerRadius, y: rect.maxY),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + bottomCornerRadius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - bottomCornerRadius),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Styles

/// One surface for every indicator style: dark glass, a light top edge and a
/// tinted glow. The shapes differ, the design language does not.
private struct GlassSurface<S: Shape>: View {
    let shape: S
    let tint: Color

    var body: some View {
        shape
            .fill(LinearGradient(colors: [Color(white: 0.18).opacity(0.96),
                                          Color(white: 0.08).opacity(0.97)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(
                shape.stroke(
                    LinearGradient(colors: [Color.white.opacity(0.28), Color.white.opacity(0.04)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.9
                )
            )
            .shadow(color: tint.opacity(0.32), radius: 16, x: 0, y: 6)
            .shadow(color: .black.opacity(0.42), radius: 10, x: 0, y: 4)
    }
}

struct IndicatorView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        switch model.style {
        case .island: IslandIndicator(model: model)
        case .notch: NotchIndicator(model: model)
        case .overlay: OverlayIndicator(model: model)
        case .minimal: MinimalIndicator(model: model)
        }
    }
}

private struct IslandIndicator: View {
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
                }
            }

            if model.showsLevel {
                IndicatorWaveform(level: model.level, tint: model.tint)
                    .padding(.leading, 2)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background {
            GlassSurface(shape: Capsule(style: .continuous), tint: model.tint)
        }
        .fixedSize()
        .preferredColorScheme(.dark)
    }

    private var badge: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [model.tint.opacity(0.95), model.tint.opacity(0.62)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 0.8))
                .shadow(color: model.tint.opacity(0.55), radius: 6, x: 0, y: 2)
            Image(systemName: model.symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 27, height: 27)
    }
}

private struct NotchIndicator: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(model.tint)

            VStack(alignment: .leading, spacing: 0) {
                Text(model.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                if let subtitle = model.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }

            Spacer(minLength: 6)

            if model.showsLevel {
                IndicatorWaveform(level: model.level, barCount: 6, tint: model.tint)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 9)
        .padding(.top, 2)
        .frame(width: 260, height: 42, alignment: .bottom)
        .background {
            GlassSurface(shape: NotchShape(bottomCornerRadius: 14), tint: model.tint)
        }
        .clipShape(NotchShape(bottomCornerRadius: 14))
        .preferredColorScheme(.dark)
    }
}

private struct OverlayIndicator: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(model.tint)

            VStack(alignment: .leading, spacing: 0) {
                Text(model.title)
                    .font(.system(size: 12.5, weight: .semibold))
                if let subtitle = model.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            if model.showsLevel {
                IndicatorWaveform(level: model.level, barCount: 6, tint: model.tint)
                    .padding(.leading, 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background {
            GlassSurface(shape: RoundedRectangle(cornerRadius: 18, style: .continuous), tint: model.tint)
        }
        .fixedSize()
        .preferredColorScheme(.dark)
    }
}

private struct MinimalIndicator: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(model.tint)
                .frame(width: 6, height: 6)
                .shadow(color: model.tint.opacity(0.9), radius: 4)
                .overlay(Circle().stroke(Color.white.opacity(0.4), lineWidth: 0.6))

            if model.showsLevel {
                IndicatorWaveform(level: model.level, barCount: 4, height: 12, tint: .white, barWidth: 2.5)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            GlassSurface(shape: Capsule(style: .continuous), tint: model.tint)
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Controller

@MainActor
final class HUDController {
    static let shared = HUDController()

    private let model = HUDModel()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var startedAt: Date?

    private init() {}

    private var style: IndicatorStyle {
        IndicatorStyle(rawValue: AppSettings.shared.indicatorStyle) ?? .island
    }

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

    /// Shows the current style for a couple of seconds, so the picker in
    /// Settings is not a blind choice.
    func preview(style: IndicatorStyle) {
        AppSettings.shared.indicatorStyle = style.rawValue
        startedAt = Date()
        model.subtitle = "0:00"
        show(title: "Preview", symbol: "mic.fill", tint: Theme.danger, level: true, error: false, autoHide: 3.0)
        startTicking()
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

        let wasHidden = !panel.isVisible
        if wasHidden {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        } else {
            panel.orderFrontRegardless()
        }

        if let autoHide {
            hideTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(autoHide * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.fadeOut() }
            }
        }
    }

    private func fadeOut() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
            panel.alphaValue = 1
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
        let desired = style
        if let panel, model.style == desired { return panel }

        closePanel()
        model.style = desired

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 44),
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
        panel.contentView = NSHostingView(rootView: IndicatorView(model: model))

        self.panel = panel
        return panel
    }

    private func closePanel() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func resize(_ panel: NSPanel) {
        guard let hosting = panel.contentView else { return }
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize

        let size: NSSize
        switch model.style {
        case .notch:
            size = NSSize(width: 260, height: 42)
        case .minimal:
            size = NSSize(width: max(52, fitting.width), height: max(26, fitting.height))
        case .island, .overlay:
            size = NSSize(width: max(140, fitting.width), height: max(38, fitting.height))
        }
        panel.setContentSize(size)
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let frame = screen.frame
        let size = panel.frame.size
        let atTop = AppSettings.shared.indicatorPosition == "top"

        func topOrigin(inset: CGFloat = 10) -> NSPoint {
            NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - inset)
        }

        func bottomOrigin(inset: CGFloat = 10) -> NSPoint {
            NSPoint(x: visible.midX - size.width / 2, y: visible.minY + inset)
        }

        switch model.style {
        case .island:
            panel.setFrameOrigin(atTop ? topOrigin() : bottomOrigin())

        case .notch:
            if atTop {
                // On a notched MacBook the panel must start below the notch, or
                // the shape is hidden behind it.
                let notch = screen.safeAreaInsets.top
                if notch > 0 {
                    panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                                                 y: frame.maxY - size.height - notch))
                } else {
                    panel.setFrameOrigin(topOrigin(inset: 6))
                }
            } else {
                panel.setFrameOrigin(bottomOrigin())
            }

        case .overlay:
            panel.setFrameOrigin(atTop ? topOrigin() : bottomOrigin())

        case .minimal:
            if atTop {
                panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 12,
                                             y: visible.maxY - size.height - 8))
            } else {
                panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 12,
                                             y: visible.minY + 10))
            }
        }
    }
}
