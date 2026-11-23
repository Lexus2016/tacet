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
            Image(systemName: controller.menuBarSymbol)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.applyActivationPolicy()
        if CLIHarness.runIfRequested() { return }

        _ = DictationController.shared
        _ = Updater.shared

        // A menu bar app with no engine looks broken: every dictation fails with
        // "not configured". Open the one window that fixes it.
        if !SetupState.hasUsableEngine {
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

    static func applyActivationPolicy() {
        NSApp.setActivationPolicy(.accessory)
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
