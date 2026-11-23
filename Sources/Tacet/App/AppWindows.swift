import AppKit
import ServiceManagement
import SwiftUI

/// Windows are created and owned here rather than by SwiftUI scenes: a menu bar
/// app needs to open Settings from the delegate (first run) and from the menu,
/// and to reuse the same window instead of stacking copies.
@MainActor
final class AppWindows {
    static let shared = AppWindows()

    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?

    private init() {}

    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = makeWindow(
                title: "Tacet — Settings",
                size: NSSize(width: 620, height: 660),
                resizable: false
            ) {
                SettingsView().environmentObject(DictationController.shared)
            }
            observe(settingsWindow)
        }
        present(settingsWindow)
    }

    func showHistory() {
        if historyWindow == nil {
            historyWindow = makeWindow(
                title: "Tacet — History",
                size: NSSize(width: 900, height: 600),
                resizable: true
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
            .contains { $0.isVisible }
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
        NSApp.activate()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow<Content: View>(title: String,
                                           size: NSSize,
                                           resizable: Bool,
                                           @ViewBuilder content: () -> Content) -> NSWindow {
        let hosting = NSHostingView(rootView: content())
        hosting.setFrameSize(size)

        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName(title)
        if !window.setFrameUsingName(title) {
            window.center()
        }
        return window
    }
}

enum SetupState {
    /// True when at least one engine can transcribe right now.
    static var hasUsableEngine: Bool {
        if Keychain.secret(KeychainAccount.groq, environment: "GROQ_API_KEY") != nil { return true }
        if Keychain.secret(KeychainAccount.openAI, environment: "OPENAI_API_KEY") != nil { return true }
        if ParakeetRecognizer.shared.isConfigured() { return true }
        return false
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
