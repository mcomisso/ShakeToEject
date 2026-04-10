import SwiftUI

struct MenuBarContent: View {
    let sensor: SensorService
    let drives: DriveMonitor
    let warningCoordinator: WarningCoordinator
    let settings: SettingsStore
    let onOpenDashboard: () -> Void

    var body: some View {
        Text("ShakeToEject \(Bundle.main.shortVersion)")
            .font(.headline)

        Text(sensor.isRunning ? "Sensor: running" : "Sensor: stopped")
        Text("Shakes: \(sensor.shakeCount)")

        if sensor.lastShakeMagnitude > 0 {
            Text(String(format: "Last magnitude: %.3f g", sensor.lastShakeMagnitude))
        }

        if warningCoordinator.isEjecting {
            Text("Ejecting…")
                .foregroundStyle(.orange)
        }

        Divider()

        if drives.drives.isEmpty {
            Text("No external drives")
                .foregroundStyle(.secondary)
        } else {
            ForEach(drives.drives) { drive in
                Text("⏏︎ \(drive.volumeName)")
            }
            Button("Eject All \(drives.drives.count) Drive\(drives.drives.count == 1 ? "" : "s")") {
                drives.ejectAll()
            }
        }

        Divider()

        Button("Settings…") {
            onOpenDashboard()
        }
        .keyboardShortcut(",")

        Button("Simulate Shake (dev)") {
            warningCoordinator.trigger(force: true)
        }

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

private extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }
}
