import AppKit
import SwiftUI

enum IndicatorTheme: String, CaseIterable, Identifiable {
    case classic
    case glass
    case light

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: return "Classic"
        case .glass: return "Glass"
        case .light: return "Light"
        }
    }
}

final class HUDModel: ObservableObject {
    @Published var title: String = ""
    @Published var subtitle: String?
    @Published var symbol: String = "mic.fill"
    @Published var showsLevel: Bool = false
    @Published var showsSpinner: Bool = false
    @Published var tint: Color = Theme.accent
    @Published var theme: IndicatorTheme = .classic
    let waveform = WaveformModel(barCount: 5)
}

// MARK: - Waveform

/// Ported from TypeWhisper's AudioWaveformBarModel: center-weighted bars, a
/// per-bar drift so they keep moving while the level holds, and attack/release
/// smoothing so they do not twitch between level updates.
/// Drives the bars from a reference-type model, so the 30 Hz animation does not
/// depend on the parent view being re-created by level updates.
final class WaveformModel: ObservableObject {
    @Published private(set) var heights: [CGFloat]

    private var level: Float = 0
    private let barCount: Int
    private var timer: Timer?
    private var lastTick: TimeInterval = 0

    init(barCount: Int) {
        self.barCount = max(1, barCount)
        heights = Array(repeating: 0, count: self.barCount)
    }

    deinit { timer?.invalidate() }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastTick = 0
        level = 0
        heights = Array(repeating: 0, count: barCount)
    }

    func setLevel(_ level: Float) {
        let wasSilent = self.level == 0
        self.level = level
        if wasSilent, level > 0 { tick(minimumElapsed: 1.0 / 30.0) }
    }

    private func tick(minimumElapsed: TimeInterval = 0.001) {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = lastTick == 0 ? 1.0 / 30.0 : min(0.1, max(minimumElapsed, now - lastTick))
        lastTick = now

        let level = CGFloat(min(1, max(0, self.level)))
        var updated = heights

        for index in 0..<barCount {
            let position = (Double(index) + 0.5) / Double(barCount)
            let shape = 0.55 + 0.45 * CGFloat(sin(.pi * position))
            let rate = 2.2 + 0.65 * Double(index)
            let phase = Double(index) * 2.1
            let drift = 0.8 + 0.2 * CGFloat(sin(now * rate + phase))
            let target = level * shape * drift
            let tau: CGFloat = target > updated[index] ? 0.04 : 0.16
            updated[index] += (target - updated[index]) * CGFloat(1 - exp(-elapsed / Double(tau)))
        }

        heights = updated
    }
}

struct IndicatorWaveform: View {
    @ObservedObject var model: WaveformModel
    var height: CGFloat = 22
    var tint: Color = .white
    var barWidth: CGFloat = 3

    var body: some View {
        HStack(spacing: 2) {
            ForEach(model.heights.indices, id: \.self) { index in
                Capsule()
                    .fill(tint)
                    .frame(width: barWidth, height: max(2, model.heights[index] * height))
            }
        }
        .frame(height: height)
    }
}

// MARK: - Shapes

struct GlassSurface<S: InsettableShape>: View {
    let shape: S
    let tint: Color
    let theme: IndicatorTheme

    var body: some View {
        switch theme {
        case .classic:
            shape
                .fill(LinearGradient(colors: [Color(white: 0.18).opacity(0.96),
                                              Color(white: 0.08).opacity(0.97)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.28), Color.white.opacity(0.04)],
                                                     startPoint: .top, endPoint: .bottom), lineWidth: 0.9))
                .shadow(color: tint.opacity(0.32), radius: 16, x: 0, y: 6)
                .shadow(color: .black.opacity(0.42), radius: 10, x: 0, y: 4)

        case .glass:
            shape
                .fill(.ultraThinMaterial)
                .overlay(shape.fill(LinearGradient(colors: [Color(red: 0.30, green: 0.39, blue: 0.51).opacity(0.46),
                                                           Color(red: 0.07, green: 0.11, blue: 0.19).opacity(0.80)],
                                                   startPoint: .top, endPoint: .bottom)))
                .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.68), .white.opacity(0.20),
                                                                Color(red: 0.59, green: 0.75, blue: 0.91).opacity(0.48)],
                                                      startPoint: .top, endPoint: .bottom), lineWidth: 1))
                .overlay(shape.inset(by: 2).strokeBorder(Color.white.opacity(0.11), lineWidth: 0.8))
                .shadow(color: tint.opacity(0.22), radius: 12, x: 0, y: 3)
                .shadow(color: .black.opacity(0.30), radius: 10, x: 0, y: 4)

        case .light:
            shape
                .fill(LinearGradient(colors: [Color.white.opacity(0.97), Color.white.opacity(0.86)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(shape.strokeBorder(Color.black.opacity(0.10), lineWidth: 0.9))
                .shadow(color: tint.opacity(0.22), radius: 16, x: 0, y: 6)
                .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
        }
    }
}

struct IndicatorView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        IslandIndicator(model: model)
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
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .frame(maxWidth: 310, alignment: .leading)
                if let subtitle = model.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if model.showsSpinner {
                ProgressView()
                    .controlSize(.small)
                    .tint(model.tint)
                    .padding(.leading, 2)
            } else if model.showsLevel {
                IndicatorWaveform(model: model.waveform, tint: model.theme == .glass
                                  ? Color(red: 0.84, green: 0.89, blue: 0.94)
                                  : model.tint)
                    .padding(.leading, 2)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 19)
        .padding(.vertical, 9)
        .frame(minWidth: model.showsSpinner || model.showsLevel ? 174 : 150)
        .background {
            GlassSurface(shape: Capsule(style: .continuous), tint: model.tint, theme: model.theme)
        }
        // The panel boundary surrounds the entire glass surface and its border.
        // Межа вікна охоплює всю скляну поверхню разом з обводкою.
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .fixedSize()
    }

    private var badge: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [model.tint.opacity(0.95), model.tint.opacity(0.62)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 0.8))
                .shadow(color: model.tint.opacity(0.55), radius: 6, x: 0, y: 2)
            Image(systemName: model.symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.primary)
        }
        .frame(width: 27, height: 27)
    }
}

// MARK: - Controller

@MainActor
final class HUDController {
    static let shared = HUDController()

    private let model = HUDModel()
    private(set) var panels: [CGDirectDisplayID: NSPanel] = [:]
    private var presentation: Presentation?
    private var spaceRefreshTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var startedAt: Date?

    private enum Presentation {
        case dictation
        case preview
    }

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.spaceDidChange() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPanels() }
        }
    }

    func showPreparing() {
        stopTicking()
        startedAt = nil
        model.subtitle = nil
        show(title: "Preparing microphone…", symbol: "mic.fill", tint: Theme.accent,
             level: false, autoHide: nil, spinner: true)
    }

    func showRecording(theme: IndicatorTheme? = nil) {
        startedAt = Date()
        model.subtitle = "0:00"
        model.waveform.setLevel(0)
        show(title: "Recording", symbol: "mic.fill", tint: Theme.accent,
             level: true, autoHide: nil, theme: theme)
        startTicking()
    }

    func showProcessing(theme: IndicatorTheme? = nil) {
        stopTicking()
        startedAt = nil
        model.subtitle = nil
        show(title: "Transcribing…", symbol: "waveform", tint: Theme.accent,
             level: false, autoHide: nil, spinner: true, theme: theme)
    }

    var previewWindow: NSWindow? {
        if let id = NSScreen.main.flatMap(displayID), let panel = panels[id] { return panel }
        return panels.values.first
    }

    func finish(error: String?) {
        guard let error else {
            hide()
            return
        }
        stopTicking()
        startedAt = nil
        model.subtitle = nil
        show(title: error,
             symbol: "exclamationmark.triangle.fill",
             tint: Theme.warning,
             level: false,
             autoHide: 2.8)
    }

    /// Shows the current style for a couple of seconds, so the picker in
    /// Settings is not a blind choice.
    func preview() {
        guard presentation != .dictation || hideTask != nil else { return }
        startedAt = Date()
        model.subtitle = "0:00"
        show(title: "Preview", symbol: "mic.fill", tint: Theme.accent, level: true, autoHide: 3.0,
             presentation: .preview)
        updateLevel(0.4)
        startTicking()
    }

    func updateLevel(_ level: Float) {
        guard model.showsLevel else { return }
        model.waveform.setLevel(level)
    }

    func hide() {
        presentation = nil
        spaceRefreshTask?.cancel()
        spaceRefreshTask = nil
        hideTask?.cancel()
        hideTask = nil
        stopTicking()
        startedAt = nil
        model.showsLevel = false
        model.waveform.stop()
        for panel in panels.values { panel.orderOut(nil) }
    }

    private func show(title: String,
                      symbol: String,
                      tint: Color,
                      level: Bool,
                      autoHide: TimeInterval?,
                      spinner: Bool = false,
                      theme: IndicatorTheme? = nil,
                      presentation: Presentation = .dictation) {
        hideTask?.cancel()
        hideTask = nil

        let desiredTheme = theme ?? IndicatorTheme(rawValue: AppSettings.shared.indicatorTheme) ?? .classic
        if model.theme != desiredTheme {
            model.theme = desiredTheme
            for panel in panels.values { panel.orderOut(nil) }
            panels.removeAll()
        }
        model.title = NSLocalizedString(title, comment: "")
        model.symbol = symbol
        model.tint = tint
        model.showsLevel = level
        model.showsSpinner = spinner
        if level { model.waveform.start() }
        else { model.waveform.stop() }

        self.presentation = presentation
        refreshPanels()

        if let autoHide {
            hideTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(autoHide * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.hide()
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
                let subtitle = String(format: "%d:%02d", seconds / 60, seconds % 60)
                guard self.model.subtitle != subtitle else { continue }
                self.model.subtitle = subtitle
                self.refreshPanels(orderFront: false)
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }

    private func spaceDidChange() {
        guard presentation != nil else { return }
        refreshPanels()
        spaceRefreshTask?.cancel()
        spaceRefreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            self?.refreshPanels(recreate: true)
        }
    }

    private func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func refreshPanels(orderFront: Bool = true, recreate: Bool = false) {
        guard let presentation else { return }
        let screens: [NSScreen]
        switch presentation {
        case .dictation:
            screens = NSScreen.screens
        case .preview:
            screens = (NSScreen.main ?? NSScreen.screens.first).map { [$0] } ?? []
        }
        let destinations = screens.compactMap { screen in displayID(screen).map { ($0, screen) } }
        let activeIDs = Set(destinations.map { $0.0 })
        for id in panels.keys.filter({ !activeIDs.contains($0) }) {
            panels.removeValue(forKey: id)?.orderOut(nil)
        }
        for (id, screen) in destinations {
            let existing = panels[id]
            let panel = (recreate ? nil : existing) ?? makePanel(on: screen)
            panels[id] = panel
            resize(panel)
            position(panel, on: screen)
            if orderFront || existing == nil { panel.orderFrontRegardless() }
            if recreate { existing?.orderOut(nil) }
        }
    }

    private func makePanel(on screen: NSScreen) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: model.theme == .light ? .aqua : .darkAqua)
        panel.contentView = NSHostingView(rootView: IndicatorView(model: model))

        return panel
    }

    private func resize(_ panel: NSPanel) {
        guard let hosting = panel.contentView else { return }
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize

        panel.setContentSize(NSSize(width: ceil(fitting.width), height: ceil(fitting.height)))
        hosting.layoutSubtreeIfNeeded()
    }

    private func position(_ panel: NSPanel, on screen: NSScreen) {
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let y = AppSettings.shared.indicatorPosition == "top"
            ? visible.maxY - size.height - 10
            : visible.minY + 10
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: y))
    }
}
