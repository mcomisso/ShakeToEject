import SwiftUI

struct MenuBarContent: View {
    let sensor: SensorService

    var body: some View {
        Text("ShakeToEject \(Bundle.main.shortVersion)")
            .font(.headline)

        if sensor.isRunning {
            Text("Sensor: running")
        } else {
            Text("Sensor: stopped")
        }

        Text("Shakes: \(sensor.shakeCount)")

        if sensor.lastShakeMagnitude > 0 {
            Text(String(format: "Last magnitude: %.3f g", sensor.lastShakeMagnitude))
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
