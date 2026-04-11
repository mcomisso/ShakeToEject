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

        // Wire real shakes → warning flow
        sensor.onShake = { [weak self] _ in
            self?.warningCoordinator.trigger()
        }

        // Start the sensor with the current settings values
        sensor.start(
            threshold: settings.sensitivityThreshold,
            cooldownSamples: settings.cooldownSamples
        )
        drives.start()
        _ = warningCoordinator // force lazy init
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
