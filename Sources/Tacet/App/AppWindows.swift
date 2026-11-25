import AppKit
import ServiceManagement
import SwiftUI

/// Windows are created and owned here rather than by SwiftUI scenes: a menu bar
/// app needs to open Settings from the delegate (first run) and from the menu,
/// and to reuse the same window instead of stacking copies.
@MainActor
final class AppWindows {
    static let shared = AppWindows()

    private static let titleBarHeight: CGFloat = 38

    static let settingsSize = NSSize(width: 840, height: 660)
    static let settingsMinimum = NSSize(width: 700, height: 480)
    static let historySize = NSSize(width: 920, height: 620)
    static let historyMinimum = NSSize(width: 680, height: 420)

    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?

    private init() {}

    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = Self.makeWindow(
                title: String(localized: "Tacet Settings"),
                size: Self.settingsSize,
                minimum: Self.settingsMinimum,
                autosaveName: "Tacet.Settings"
            ) {
                SettingsView().environmentObject(DictationController.shared)
            }
            observe(settingsWindow)
        }
        present(settingsWindow)
    }

    func showHistory() {
        if historyWindow == nil {
            historyWindow = Self.makeWindow(
                title: String(localized: "Tacet History"),
                size: Self.historySize,
                minimum: Self.historyMinimum,
                autosaveName: "Tacet.History"
            ) {
                HistoryView().environmentObject(DictationController.shared)
            }
            observe(historyWindow)
        }
        DictationController.shared.refreshHistory()
        present(historyWindow)
    }

    /// The Dock icon is a window affordance, not a permanent badge: the app is
    /// invisible until Settings or History is open.
    private func observe(_ window: NSWindow?) {
        guard let window else { return }
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            DispatchQueue.main.async {
                AppWindows.shared.updatePolicy()
            }
        }
    }

    private func updatePolicy() {
        let hasVisibleWindow = [settingsWindow, historyWindow]
            .compactMap { $0 }
            .contains { $0.isVisible || $0.isMiniaturized }
        NSApp.setActivationPolicy(hasVisibleWindow ? .regular : .accessory)
    }

    /// Called when the update UI closes: back to a menu bar only app unless a
    /// real window is still open.
    func restoreAccessoryIfPossible() {
        updatePolicy()
    }

    private func present(_ window: NSWindow?) {
        guard let window else { return }
        NSApp.setActivationPolicy(.regular)
        TacetIcon.applyToDock()
        NSApp.activate()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    static func makeWindow<Content: View>(title: String,
                                          size: NSSize,
                                          minimum: NSSize,
                                          autosaveName: String? = nil,
                                          @ViewBuilder content: () -> Content) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = .windowBackgroundColor
        window.isOpaque = true
        window.isMovable = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = minimum

        let hosting = NSHostingView(rootView:
            VStack(spacing: 0) {
                WindowTitleBar(title: title)
                    .frame(height: titleBarHeight)
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .ignoresSafeArea(edges: .top)
        )
        hosting.setFrameSize(size)
        window.contentView = hosting

        if let autosaveName {
            if !window.setFrameUsingName(autosaveName) { window.center() }
            window.setFrameAutosaveName(autosaveName)
        } else {
            window.center()
        }
        if let screen = window.screen ?? NSScreen.main {
            window.setFrame(window.constrainFrameRect(window.frame, to: screen), display: false)
        }
        return window
    }
}

private struct WindowTitleBar: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        WindowDragBar(title: title)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowDragBar: NSView {
    override var isOpaque: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    private var dragStart: (pointer: NSPoint, windowOrigin: NSPoint)?

    init(title: String) {
        super.init(frame: .zero)

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(1).setFill()
        dirtyRect.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: 1).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point).map { _ in self }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragStart = (screenPoint(for: event, in: window), window.frame.origin)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let dragStart else { return }
        let pointer = screenPoint(for: event, in: window)
        var frame = window.frame
        frame.origin = NSPoint(x: dragStart.windowOrigin.x + pointer.x - dragStart.pointer.x,
                               y: dragStart.windowOrigin.y + pointer.y - dragStart.pointer.y)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? window.screen {
            frame = window.constrainFrameRect(frame, to: screen)
        }
        window.setFrameOrigin(frame.origin)
    }

    private func screenPoint(for event: NSEvent, in window: NSWindow) -> NSPoint {
        if let location = event.cgEvent?.location, let primaryScreen = NSScreen.screens.first {
            return NSPoint(x: location.x, y: primaryScreen.frame.maxY - location.y)
        }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
    }
}

enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
