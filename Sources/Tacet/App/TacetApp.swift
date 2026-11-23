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

        Settings {
            SettingsView()
                .environmentObject(controller)
        }

        Window("History", id: "history") {
            HistoryView()
                .environmentObject(controller)
        }
        .defaultSize(width: 780, height: 540)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if CLIHarness.runIfRequested() { return }
        _ = DictationController.shared
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

struct MenuBarView: View {
    @EnvironmentObject private var controller: DictationController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            Text(controller.statusNote)
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
                openWindow(id: "history")
                NSApp.activate()
            }

            SettingsLink {
                Text("Settings…")
            }

            Divider()

            Button("Quit Tacet") {
                NSApp.terminate(nil)
            }
        }
    }
}
