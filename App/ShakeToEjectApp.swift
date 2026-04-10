import SwiftUI

@main
struct ShakeToEjectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(sensor: appDelegate.sensor)
        } label: {
            Image(systemName: "eject.circle")
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let sensor = SensorService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        sensor.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        sensor.stop()
    }
}
