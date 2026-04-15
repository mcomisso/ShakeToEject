import SwiftUI

struct MenuBarContent: View {
    let sensor: SensorService
    let drives: DriveMonitor
    let warningCoordinator: WarningCoordinator
    let settings: SettingsStore
    let updater: UpdaterService
    let onOpenDashboard: () -> Void

    var body: some View {
        Text("\(Bundle.main.displayName) \(Bundle.main.shortVersion)")
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
                let excluded = settings.excludedVolumeNames.contains(drive.volumeName)
                Text("\(excluded ? "🔒" : "⏏︎") \(drive.volumeName)")
                    .foregroundStyle(excluded ? .secondary : .primary)
            }
            let ejectable = drives.drives.filter {
                !settings.excludedVolumeNames.contains($0.volumeName)
            }
            if !ejectable.isEmpty {
                Button("Eject All \(ejectable.count) Drive\(ejectable.count == 1 ? "" : "s")") {
                    drives.eject(ejectable)
                }
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

        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)

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
