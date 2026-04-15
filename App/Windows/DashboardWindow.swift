import AppKit
import SwiftUI

/// A regular titled window hosting the settings dashboard. Unlike
/// `WarningOverlayWindow` this is a normal user-facing window: it
/// has a title bar, can be dragged and closed, remembers its
/// position via the default autosave name.
final class DashboardWindow: NSWindow {
    init<Content: View>(rootView: Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 440),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        title = "\(Bundle.main.displayName) Settings"
        isReleasedWhenClosed = false
        setFrameAutosaveName("ShakeToEject.Dashboard")
        contentView = NSHostingView(rootView: rootView)
    }
}
