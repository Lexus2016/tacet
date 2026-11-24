import AppKit
import Sparkle

/// Sparkle checks the GitHub release feed in the background and offers the
/// standard update window.
///
/// The app is a menu bar agent, so a plain update alert would open behind other
/// windows. The delegate brings the app forward while the update UI is on
/// screen and returns it to the background afterwards.
@MainActor
final class Updater: NSObject, @preconcurrency SPUStandardUserDriverDelegate {
    static let shared = Updater()

    private var controller: SPUStandardUpdaterController?

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
    }

    func checkForUpdates() {
        NSApp.setActivationPolicy(.regular)
        controller?.checkForUpdates(nil)
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
