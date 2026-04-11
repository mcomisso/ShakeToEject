import AppKit
import Foundation

/// RAII-style wrapper around `NSEvent.addGlobalMonitorForEvents`
/// and `addLocalMonitorForEvents`. The monitor is installed on
/// `install(onEscape:)` and torn down on `remove()` or deinit.
///
/// We install BOTH a local and a global monitor so Esc works
/// whether or not our app is foreground: global catches keydowns
/// sent to other apps (the nonactivating notch panel case), local
/// catches keydowns inside our own windows (the fullscreen case).
@MainActor
final class KeyEventMonitor {
    nonisolated(unsafe) private var globalMonitor: Any?
    nonisolated(unsafe) private var localMonitor: Any?

    func install(onEscape: @escaping @MainActor () -> Void) {
        remove() // idempotent

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // kVK_Escape
                Task { @MainActor in
                    onEscape()
                }
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                Task { @MainActor in
                    onEscape()
                }
                return nil // consume
            }
            return event
        }
    }

    func remove() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    deinit {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
