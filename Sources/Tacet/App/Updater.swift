import AppKit
import Sparkle

/// Sparkle checks the GitHub release feed in the background and offers the
/// standard update window.
///
/// The app is a menu bar agent, so a plain update alert would open behind other
/// windows. The delegate brings the app forward while the update UI is on
/// screen and returns it to the background afterwards.
@MainActor
final class Updater: NSObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    static let shared = Updater()

    private var controller: SPUStandardUpdaterController?
    private var restartTask: Task<Void, Never>?

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
    }

    func checkForUpdates() {
        NSApp.setActivationPolicy(.regular)
        controller?.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock install: @escaping () -> Void) -> Bool {
        guard updater.automaticallyDownloadsUpdates else { return false }
        restartTask?.cancel()
        restartTask = Task { [weak updater] in
            while !Task.isCancelled, let updater {
                if updater.automaticallyDownloadsUpdates, DictationController.shared.reserveUpdateRestart() {
                    install()
                    return
                }
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        guard let restartTask else { return }
        restartTask.cancel()
        self.restartTask = nil
        DictationController.shared.releaseUpdateRestart()
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                   forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func standardUserDriverWillFinishUpdateSession() {
        AppWindows.shared.restoreAccessoryIfPossible()
    }
}

struct UpdateRestartGate {
    var activeTranscriptions = 0
    private(set) var isRestarting = false

    mutating func reserve(isIdle: Bool) -> Bool {
        guard isIdle, activeTranscriptions == 0, !isRestarting else { return false }
        isRestarting = true
        return true
    }

    mutating func release() {
        isRestarting = false
    }
}
