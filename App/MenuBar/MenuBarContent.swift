import SwiftUI

struct MenuBarContent: View {
    var body: some View {
        Text("ShakeToEject \(Bundle.main.shortVersion)")
            .font(.headline)

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
