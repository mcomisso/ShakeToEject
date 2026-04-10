import AppKit
import SwiftUI

/// Borderless full-screen always-on-top window that hosts the
/// `WarningView`. Sized to cover the main screen, positioned at the
/// `.screenSaver` window level so it draws above menu bars, Dock,
/// and even other apps in full-screen mode.
///
/// `canBecomeKey` is overridden to true so the SwiftUI `keyboardShortcut(.escape)`
/// on the Cancel button actually receives the Esc keystroke — a
/// borderless `NSWindow` is non-key by default.
final class WarningOverlayWindow: NSWindow {
    init<Content: View>(rootView: Content) {
        let screen = NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
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

        contentView = NSHostingView(rootView: rootView)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
