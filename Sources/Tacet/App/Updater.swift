import AppKit
import Sparkle

/// Sparkle checks the GitHub release feed in the background and offers the
/// standard update window. The feed is the appcast attached to the latest
/// release, so publishing a release is all it takes to ship an update.
@MainActor
final class Updater {
    static let shared = Updater()

    private let controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    private init() {}

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }
}
