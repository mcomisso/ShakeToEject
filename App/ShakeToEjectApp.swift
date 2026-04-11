import AppKit
import SwiftUI

@main
struct ShakeToEjectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(
                sensor: appDelegate.sensor,
                drives: appDelegate.drives,
                warningCoordinator: appDelegate.warningCoordinator,
                settings: appDelegate.settings,
                onOpenDashboard: { [weak appDelegate] in
                    appDelegate?.openDashboard()
                }
            )
        } label: {
            Image(systemName: "eject.circle")
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let sensor = SensorService()
    let drives = DriveMonitor()
    let settings = SettingsStore()
    let notifications = NotificationService()
    lazy var soundPlayer = SoundPlayer(settings: settings)
    lazy var warningCoordinator = WarningCoordinator(
        driveMonitor: drives,
        soundPlayer: soundPlayer,
        settings: settings
    )

    private var dashboardWindow: DashboardWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Wire settings → sensor for live updates
        settings.onSensitivityChange = { [weak self] value in
            self?.sensor.setThreshold(value)
        }
        settings.onCooldownChange = { [weak self] samples in
            self?.sensor.setCooldownSamples(samples)
        }

        // When the user flips the shake-action picker to notifyOnly,
        // prompt for notification permission right away so the dialog
        // appears in context instead of on first shake.
        settings.onShakeActionChange = { [weak self] action in
            guard action == .notifyOnly else { return }
            Task { @MainActor [weak self] in
                _ = await self?.notifications.ensureAuthorization()
            }
        }

        // Wire real shakes → response based on the current mode.
        sensor.onShake = { [weak self] _ in
            self?.handleShake()
        }

        // Start the sensor with the current settings values
        sensor.start(
            threshold: settings.sensitivityThreshold,
            cooldownSamples: settings.cooldownSamples
        )
        drives.start()
        _ = warningCoordinator // force lazy init
    }

    /// Routes a detected shake to the appropriate response:
    /// - `.ejectWithWarning` and `.warnOnly` → fullscreen warning
    ///   (the coordinator itself decides whether to eject at the end).
    /// - `.notifyOnly` → post a macOS notification, or fall back to
    ///   the fullscreen warning flow if notifications aren't allowed.
    private func handleShake() {
        switch settings.shakeAction {
        case .ejectWithWarning, .warnOnly:
            warningCoordinator.trigger()

        case .notifyOnly:
            let eligibleCount = drives.drives
                .filter { !settings.excludedVolumeNames.contains($0.volumeName) }
                .count
            Task { @MainActor [weak self] in
                guard let self else { return }
                let posted = await self.notifications.postShakeNotification(driveCount: eligibleCount)
                if !posted {
                    NSLog("[app] notifyOnly mode failed to post — falling back to overlay")
                    self.warningCoordinator.trigger()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        sensor.stop()
        drives.stop()
    }

    /// Creates-or-shows the settings window. Idempotent; subsequent
    /// calls just bring the existing window to the front.
    func openDashboard() {
        if let existing = dashboardWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = DashboardView(settings: settings, drives: drives, soundPlayer: soundPlayer)
        let window = DashboardWindow(rootView: view)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        dashboardWindow = window
    }
}
