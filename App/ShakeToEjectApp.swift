import SwiftUI

@main
struct ShakeToEjectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(
                sensor: appDelegate.sensor,
                drives: appDelegate.drives,
                warningCoordinator: appDelegate.warningCoordinator
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
    let soundPlayer = SoundPlayer()
    lazy var warningCoordinator = WarningCoordinator(
        driveMonitor: drives,
        soundPlayer: soundPlayer
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Wire real shake events to the warning flow. `trigger()` is
        // a no-op when no drives are mounted (force: false), so shaking
        // the laptop with nothing plugged in stays silent.
        sensor.onShake = { [weak self] _ in
            self?.warningCoordinator.trigger()
        }
        sensor.start()
        drives.start()
        _ = warningCoordinator // force lazy init
    }

    func applicationWillTerminate(_ notification: Notification) {
        sensor.stop()
        drives.stop()
    }
}
