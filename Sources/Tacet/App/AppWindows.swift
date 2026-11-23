import AppKit
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
                title: "Settings",
                size: NSSize(width: 620, height: 660),
                resizable: false
            ) {
                SettingsView().environmentObject(DictationController.shared)
            }
        }
        present(settingsWindow)
    }

    func showHistory() {
        if historyWindow == nil {
            historyWindow = makeWindow(
                title: "History",
                size: NSSize(width: 900, height: 600),
                resizable: true
            ) {
                HistoryView().environmentObject(DictationController.shared)
            }
        }
        DictationController.shared.refreshHistory()
        present(historyWindow)
    }

    private func present(_ window: NSWindow?) {
        guard let window else { return }
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
