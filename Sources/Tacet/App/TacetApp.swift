import AppKit
import SwiftUI

@main
struct TacetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = DictationController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(controller)
        } label: {
            Image(nsImage: controller.menuBarMark.image)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private weak var dictation: DictationController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.applyActivationPolicy()
        TacetIcon.applyToDock()
        if CLIHarness.runIfRequested() { return }
#if DEBUG
        if NSClassFromString("XCTestCase") != nil { return }
#endif

        dictation = DictationController.shared
        dictation?.recoverAtLaunch()
        // Tacet Solo is part of the product: fetch its model in the background once an account is connected.
        // Tacet Solo — частина продукту: завантажуємо його модель у фоні, щойно акаунт підключено.
        Task {
            let connected = ProviderCatalog.spec(EngineID.hostedGateway).flatMap(ProviderCatalog.key(for:)) != nil
            _ = await SoloDownload.shared.startIfAppropriate(connected: connected, canAsk: false)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(workspaceWillSleep(_:)), name: NSWorkspace.willSleepNotification, object: nil
        )
#if !DEBUG
        ProviderHealth.shared.start()
        if !ProviderCatalog.usesPilotGateway { _ = Updater.shared }
#endif

        if AppSettings.shared.gatewayActivationIssue != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                AppWindows.shared.showSettings()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            AppWindows.shared.showSettings()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        dictation?.interruptRecording()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func workspaceWillSleep(_ notification: Notification) {
        dictation?.interruptRecording()
    }

    static func applyActivationPolicy() {
        NSApp.setActivationPolicy(.accessory)
    }
}

@MainActor
enum TacetIcon {
    static let image: NSImage = {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            return icon
        }
        return NSApp.applicationIconImage
    }()

    static func applyToDock() {
        NSApp.applicationIconImage = image
    }
}

struct MenuBarView: View {
    @EnvironmentObject private var controller: DictationController

    var body: some View {
        Group {
            Text(controller.statusNote)
            Text(controller.hotkeyHint)
            if controller.pendingCount > 0 {
                Text("\(controller.pendingCount) recording\(controller.pendingCount == 1 ? "" : "s") waiting — open History")
            }
            if controller.hotkeyConflict {
                Text("Hotkey conflict, choose another in Settings")
            }

            Divider()

            Button(controller.phase == .recording ? "Stop dictation" : "Start dictation") {
                controller.toggle()
            }
            .disabled(controller.phase == .processing)

            Button("Cancel recording") {
                controller.cancelRecording()
            }
            .disabled(controller.phase != .recording)

            Divider()

            Button("Copy last dictation") {
                controller.copyLast()
            }

            Button(controller.pasteHotkeyAvailable
                   ? String(localized: "Paste last dictation") + "   " + DictationController.pasteShortcut
                   : String(localized: "Paste last dictation")) {
                controller.pasteLast()
            }
            .disabled(controller.phase != .idle)

            Button("History…") {
                AppWindows.shared.showHistory()
            }

            Button("Settings…") {
                AppWindows.shared.showSettings()
            }

            Button("Check for Updates…") {
                Updater.shared.checkForUpdates()
            }

            Divider()

            Button("Quit Tacet") {
                NSApp.terminate(nil)
            }
        }
    }
}
