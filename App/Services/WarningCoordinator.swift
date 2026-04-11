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

    /// True while the exit animation is playing after a cancel or
    /// complete, before the windows are actually `orderOut`'d.
    /// Views observe this to drive their fade/collapse animations.
    private(set) var isDismissing: Bool = false

    /// How long to give SwiftUI to play the dismissal animation
    /// before we tear the windows down.
    static let dismissAnimationDuration: Double = 0.30

    /// One of a small pool of in-character panic lines, picked at
    /// random on each `trigger()` call so successive warnings feel
    /// varied.
    private(set) var currentPanicLine: String = ""

    private static let panicLines: [String] = [
        "THEY MOVED US!!",
        "QUICK, BEFORE THEY DROP US!",
        "NOT THE TRASH CAN AGAIN!",
        "WE HAVEN'T EVEN BEEN BACKED UP!",
        "EARTHQUAKE!!!",
        "IS THIS A NORMAL TUESDAY?",
        "HELP HELP HELP",
        "TELL MY FILES I LOVE THEM",
        "PLEASE PUT US DOWN",
        "WHOA WHOA WHOA",
    ]

    /// Safety timeout on the ejection watcher, in seconds. If a
    /// drive dissents and never disappears, we clear `isEjecting`
    /// after this interval so the user is not stuck with a
    /// permanently-silent app.
    static let ejectionWatcherTimeoutSeconds: Double = 10.0

    private let driveMonitor: DriveMonitor
    private let soundPlayer: SoundPlayer
    private let settings: SettingsStore

    private var windows: [NSWindow] = []
    private let keyMonitor = KeyEventMonitor()
    private var countdownTask: Task<Void, Never>?
    private var ejectingWatchTask: Task<Void, Never>?

    init(driveMonitor: DriveMonitor, soundPlayer: SoundPlayer, settings: SettingsStore) {
        self.driveMonitor = driveMonitor
        self.soundPlayer = soundPlayer
        self.settings = settings
    }

    // MARK: - Public flow

    /// Starts the warning flow. The countdown length is taken from the
    /// `SettingsStore` unless overridden via `overrideCountdown` (used
    /// by dev/test paths that want a specific value).
    func trigger(force: Bool = false, overrideCountdown: Int? = nil) {
        guard !isShowing else { return }

        guard !isEjecting else {
            NSLog("[warning] trigger ignored — ejection in progress")
            return
        }

        drivesSnapshot = driveMonitor.drives.filter {
            !settings.excludedVolumeNames.contains($0.volumeName)
        }

        if drivesSnapshot.isEmpty && !force {
            NSLog("[warning] trigger ignored — no eligible drives to eject")
            return
        }

        let countdown = overrideCountdown ?? settings.countdownSeconds
        totalSeconds = countdown
        secondsRemaining = countdown
        isShowing = true

        currentPanicLine = Self.panicLines.randomElement() ?? "HOLD ON!"

        soundPlayer.playWarning()
        showWindow()
        startCountdown()
    }

    /// Aborts the flow — hides the window, cancels the countdown,
    /// does NOT eject drives. Safe to call when not showing.
    func cancel() {
        guard isShowing, !isDismissing else { return }
        NSLog("[warning] cancelled by user")
        countdownTask?.cancel()
        countdownTask = nil
        beginDismissal()
    }

    // MARK: - Private flow

    private func complete() {
        let drivesToEject = drivesSnapshot // already filtered at trigger() time
        let expectedBSDNames = Set(drivesToEject.map(\.id))
        countdownTask = nil

        switch settings.shakeAction {
        case .ejectWithWarning:
            NSLog("[warning] countdown complete — ejecting \(expectedBSDNames.count) drive(s)")
            soundPlayer.playEjected()
            driveMonitor.eject(drivesToEject)

            // Enter the ejection-in-progress grace window so shakes
            // during the actual unmount + eject work are suppressed.
            if !expectedBSDNames.isEmpty {
                isEjecting = true
                startEjectionWatcher(expectedBSDNames: expectedBSDNames)
            }

        case .warnOnly:
            // User picked "warn only" — play no celebratory sound,
            // don't touch the drives, don't enter the ejecting grace
            // window. The dismissal animation still runs so the
            // overlay goes away cleanly.
            NSLog("[warning] countdown complete — warn-only mode, skipping eject")

        case .notifyOnly:
            // `.notifyOnly` routes around WarningCoordinator entirely
            // in AppDelegate, so reaching complete() here means
            // something rerouted a shake through trigger() anyway
            // (for example, the dev menu's "force overlay" action).
            // Treat it as warn-only: no eject, no sound.
            NSLog("[warning] countdown complete — notify-only mode reached overlay path, skipping eject")
        }

        beginDismissal()
    }

    /// Starts the exit animation by flipping `isDismissing` and
    /// schedules the actual window teardown after the animation
    /// duration so SwiftUI has time to play the fade/collapse.
    private func beginDismissal() {
        isDismissing = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(Self.dismissAnimationDuration * 1000)))
            guard let self else { return }
            self.tearDown()
            self.isDismissing = false
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
        // Install Esc handler first so it's ready before any
        // window appears.
        keyMonitor.install { [weak self] in
            self?.cancel()
        }

        NSApp.activate(ignoringOtherApps: true)

        let screens = NSScreen.screens
        let effectiveStyle = settings.warningStyle

        NSLog("[warning] style=\(effectiveStyle.rawValue), NSScreen.screens.count=\(screens.count)")
        for (index, screen) in screens.enumerated() {
            let notchHeight = NotchDetector.notchHeight(for: screen)
            NSLog("[warning]   screen[\(index)] name=\"\(screen.localizedName)\" frame=\(screen.frame) notchHeight=\(notchHeight)")
        }

        for screen in screens {
            let hasNotch = NotchDetector.hasNotch(screen)
            let useNotch: Bool

            switch effectiveStyle {
            case .fullscreen:
                useNotch = false
            case .notch, .auto:
                useNotch = hasNotch
            }

            let window: NSWindow
            if useNotch {
                let view = NotchCapsuleView(coordinator: self)
                window = NotchCapsuleWindow(screen: screen, rootView: view)
                NSLog("[warning]   → notch capsule on \"\(screen.localizedName)\"")
            } else {
                if effectiveStyle == .notch {
                    NSLog("[warning]   → notch style requested but \"\(screen.localizedName)\" has no notch — falling back to fullscreen")
                } else {
                    NSLog("[warning]   → fullscreen on \"\(screen.localizedName)\"")
                }
                let view = WarningView(coordinator: self)
                window = WarningOverlayWindow(screen: screen, rootView: view)
            }

            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }

        NSLog("[warning] presented on \(windows.count) screen(s)")
    }

    private func hideWindow() {
        keyMonitor.remove()
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
    }
}
