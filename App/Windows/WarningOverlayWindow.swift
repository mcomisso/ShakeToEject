import AppKit
import SwiftUI

/// Borderless full-screen always-on-top window that hosts the
/// `WarningView` on a specific screen. One instance is created
/// per display during a warning flow when `.fullscreen` style
/// is in effect (either by user choice or by fallback from
/// `.notch` / `.auto` on non-notched screens).
final class WarningOverlayWindow: NSWindow {
    init<Content: View>(screen: NSScreen, rootView: Content) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        ignoresMouseEvents = false
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]

        // Pin the window to the given screen so it draws in the
        // right place on multi-monitor setups.
        setFrame(screen.frame, display: false)

        contentView = NSHostingView(rootView: rootView)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
