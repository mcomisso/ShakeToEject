import AppKit
import Foundation
import Observation

/// Owns the end-to-end warning flow: showing the overlay window,
/// running the countdown, playing sounds, cancelling on user action
/// or timer completion, and (when the timer completes) telling the
/// `DriveMonitor` to eject all mounted drives.
///
/// The coordinator is `@MainActor` so it can touch `NSWindow` and
/// drive @Observable state that SwiftUI views bind to. The countdown
/// runs as a `Task` that inherits main-actor isolation and therefore
/// can mutate `secondsRemaining` without any actor hops.
///
/// This type is deliberately dormant until someone calls `trigger()`.
/// It has no `start()`/`stop()` lifecycle; the owning `AppDelegate`
/// simply instantiates it once at launch and discards it at quit.
@MainActor
@Observable
final class WarningCoordinator {
    /// True while the overlay is visible (i.e. between `trigger()`
    /// and either `cancel()` or the automatic `complete()` path).
    private(set) var isShowing: Bool = false

    /// Seconds left on the current countdown. `0` when not showing.
    private(set) var secondsRemaining: Int = 0

    /// The initial countdown value for the currently-showing warning.
    /// `0` when not showing. Exposed so the view can render a progress
    /// bar or ring proportional to the original length.
    private(set) var totalSeconds: Int = 0

    /// Snapshot of the drive list taken at `trigger()` time. The view
    /// reads this so it shows the right count even if drives appear
    /// or disappear during the countdown.
    private(set) var drivesSnapshot: [DriveInfo] = []

    /// True between `complete()` firing drive ejection and the
    /// moment all of those drives have actually disappeared from
    /// `DriveMonitor.drives` (or a safety timeout expires). While
    /// this flag is set, `trigger()` is a no-op so a laptop that
    /// keeps moving during the post-countdown ejection window does
    /// not produce a second overlay on top of drives that are
    /// already on their way out.
    private(set) var isEjecting: Bool = false

    /// Safety timeout on the ejection watcher, in seconds. If a
    /// drive dissents and never disappears, we clear `isEjecting`
    /// after this interval so the user is not stuck with a
    /// permanently-silent app.
    static let ejectionWatcherTimeoutSeconds: Double = 10.0

    private let driveMonitor: DriveMonitor
    private let soundPlayer: SoundPlayer

    private var window: WarningOverlayWindow?
    private var countdownTask: Task<Void, Never>?
    private var ejectingWatchTask: Task<Void, Never>?

    init(driveMonitor: DriveMonitor, soundPlayer: SoundPlayer) {
        self.driveMonitor = driveMonitor
        self.soundPlayer = soundPlayer
    }

    // MARK: - Public flow

    /// Starts the warning flow: snaps the current drive list, shows
    /// the overlay window, plays the warning sound, and begins the
    /// countdown. No-op if the overlay is already showing.
    ///
    /// Set `force: true` to show the overlay even when no drives are
    /// mounted — used by the dev-only "Simulate Shake" menu item so
    /// the flow can be exercised without a physical drive plugged in.
    func trigger(countdownSeconds: Int = 5, force: Bool = false) {
        guard !isShowing else { return }

        guard !isEjecting else {
            NSLog("[warning] trigger ignored — ejection in progress")
            return
        }

        drivesSnapshot = driveMonitor.drives

        if drivesSnapshot.isEmpty && !force {
            NSLog("[warning] trigger ignored — no drives to eject")
            return
        }

        totalSeconds = countdownSeconds
        secondsRemaining = countdownSeconds
        isShowing = true

        soundPlayer.playWarning()
        showWindow()
        startCountdown()
    }

    /// Aborts the flow — hides the window, cancels the countdown,
    /// does NOT eject drives. Safe to call when not showing.
    func cancel() {
        guard isShowing else { return }
        NSLog("[warning] cancelled by user")
        countdownTask?.cancel()
        countdownTask = nil
        tearDown()
    }

    // MARK: - Private flow

    private func complete() {
        let expectedBSDNames = Set(drivesSnapshot.map(\.id))
        NSLog("[warning] countdown complete — ejecting \(expectedBSDNames.count) drive(s)")
        soundPlayer.playEjected()
        driveMonitor.ejectAll()
        countdownTask = nil
        tearDown()

        // Enter the ejection-in-progress grace window so shakes during
        // the actual unmount + eject work are suppressed.
        if !expectedBSDNames.isEmpty {
            isEjecting = true
            startEjectionWatcher(expectedBSDNames: expectedBSDNames)
        }
    }

    private func tearDown() {
        hideWindow()
        isShowing = false
        secondsRemaining = 0
        totalSeconds = 0
        drivesSnapshot = []
    }

    /// Polls `driveMonitor.drives` until every BSD name in
    /// `expectedBSDNames` has disappeared from the live list, or
    /// until `ejectionWatcherTimeoutSeconds` elapses. When the loop
    /// exits it clears `isEjecting` so the next real shake is
    /// allowed to trigger a fresh warning.
    private func startEjectionWatcher(expectedBSDNames: Set<String>) {
        ejectingWatchTask?.cancel()
        ejectingWatchTask = Task { [weak self] in
            let deadline = ContinuousClock.now + .seconds(Self.ejectionWatcherTimeoutSeconds)
            while !Task.isCancelled, ContinuousClock.now < deadline {
                guard let self else { return }
                let currentBSDNames = Set(self.driveMonitor.drives.map(\.id))
                if currentBSDNames.intersection(expectedBSDNames).isEmpty {
                    NSLog("[warning] ejection complete — all snapshot drives gone")
                    break
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
            if ContinuousClock.now >= deadline {
                NSLog("[warning] ejection watcher timed out after \(Self.ejectionWatcherTimeoutSeconds)s")
            }
            self?.isEjecting = false
            self?.ejectingWatchTask = nil
        }
    }

    private func startCountdown() {
        countdownTask = Task { [weak self] in
            guard let self else { return }
            // secondsRemaining starts at totalSeconds (set by trigger).
            // Tick once per second; completion fires after the last tick.
            while self.secondsRemaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                self.secondsRemaining -= 1
            }
            if !Task.isCancelled {
                self.complete()
            }
        }
    }

    private func showWindow() {
        let view = WarningView(coordinator: self)
        let newWindow = WarningOverlayWindow(rootView: view)
        window = newWindow
        NSApp.activate(ignoringOtherApps: true)
        newWindow.makeKeyAndOrderFront(nil)
    }

    private func hideWindow() {
        window?.orderOut(nil)
        window = nil
    }
}
