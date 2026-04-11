import AppKit
import Foundation

/// Utility for asking a screen whether it has a hardware notch.
enum NotchDetector {
    /// Approximate horizontal width of the notch cutout on M-series
    /// notched MacBook Pros. AppKit does not expose the exact value;
    /// 200 pt is a safe approximation that looks correct across
    /// 14" and 16" models.
    static let approximateNotchWidth: CGFloat = 200.0

    /// Height of the notch area from the top of the screen, in points.
    /// Returns 0 on non-notched screens.
    static func notchHeight(for screen: NSScreen) -> CGFloat {
        screen.safeAreaInsets.top
    }

    /// True if the given screen has a hardware notch.
    static func hasNotch(_ screen: NSScreen) -> Bool {
        notchHeight(for: screen) > 0
    }

    /// Returns the origin and initial size of a notch-hugging
    /// window for a given screen. The returned rectangle sits
    /// directly under the notch cutout.
    static func initialNotchFrame(for screen: NSScreen) -> NSRect {
        let height = notchHeight(for: screen)
        let width = approximateNotchWidth
        let x = screen.frame.midX - width / 2.0
        let y = screen.frame.maxY - height
        return NSRect(x: x, y: y, width: width, height: height)
    }

    /// Returns the fully-expanded frame of a notch capsule: still
    /// pinned under the notch, but wider and taller.
    static func expandedNotchFrame(for screen: NSScreen, expandedWidth: CGFloat = 480, expandedHeight: CGFloat = 92) -> NSRect {
        let notchHeight = notchHeight(for: screen)
        let x = screen.frame.midX - expandedWidth / 2.0
        // Keep the top of the window flush against the bottom of the notch cutout.
        let y = screen.frame.maxY - notchHeight - (expandedHeight - notchHeight)
        return NSRect(x: x, y: y, width: expandedWidth, height: expandedHeight)
    }
}
