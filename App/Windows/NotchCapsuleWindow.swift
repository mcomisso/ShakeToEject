import AppKit
import SwiftUI

/// Borderless nonactivating `NSPanel` that emerges from under the
/// hardware notch on notched MacBooks. It does not become key,
/// does not steal focus, and draws above almost everything at
/// `.screenSaver` level.
///
/// Positioning is computed by `NotchDetector.expandedNotchFrame`.
/// The window is shown at full size immediately; the *content*
/// inside it animates the drop-expansion effect via SwiftUI.
final class NotchCapsuleWindow: NSPanel {
    init<Content: View>(screen: NSScreen, rootView: Content) {
        let frame = NotchDetector.expandedNotchFrame(for: screen)

        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        ignoresMouseEvents = false
        isFloatingPanel = true
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]
        hidesOnDeactivate = false

        contentView = NSHostingView(rootView: rootView)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
