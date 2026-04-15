import Foundation
import Observation
import Sparkle

/// Thin wrapper around Sparkle's `SPUStandardUpdaterController` so
/// SwiftUI views can read/bind auto-check state without importing
/// Sparkle directly. Owns exactly one updater controller for the
/// app's lifetime; create once in `AppDelegate`.
///
/// Feed URL and public EdDSA key come from the bundle Info.plist
/// (`SUFeedURL`, `SUPublicEDKey`) — both injected by XcodeGen via
/// `INFOPLIST_KEY_*` build settings. With a placeholder public key
/// Sparkle fails closed: it will refuse to install any update,
/// which is the safe behavior until the real key is generated.
@MainActor
@Observable
final class UpdaterService {
    private let controller: SPUStandardUpdaterController

    /// Mirrors `updater.automaticallyChecksForUpdates`. Writing
    /// pushes the new value into Sparkle, which persists it to
    /// `UserDefaults` under its own key.
    var automaticallyChecksForUpdates: Bool {
        didSet {
            controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    /// True when a check can be kicked off right now. Views bind
    /// their button/menu-item `disabled` state to the negation.
    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    init() {
        // startingUpdater: true — begin the scheduled-check loop
        // immediately. Delegates are nil; Sparkle's default UI
        // (progress window, "up to date" alert, install prompt)
        // is sufficient for v1 and matches user expectations on
        // macOS.
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
    }

    /// User-initiated check. Sparkle always shows UI for this path
    /// (progress, then either "up to date" or the update prompt),
    /// regardless of whether a scheduled check has recently run.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
