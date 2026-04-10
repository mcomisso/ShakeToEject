import Foundation

/// Immutable snapshot of a mounted external drive at a moment in time.
///
/// Identity is the BSD device name (e.g. `disk4s2`) — stable across a
/// single plug-in/unplug lifecycle of a drive, and independent of the
/// volume name which the user can rename at any time.
///
/// `DriveInfo` is value-type-pure on purpose so that SwiftUI view
/// diffing can rely on `Equatable` conformance to detect changes.
struct DriveInfo: Identifiable, Equatable, Hashable {
    /// BSD name, e.g. `"disk4s2"`. Also the `id` for `Identifiable`.
    let id: String

    /// User-visible volume name, e.g. `"My External SSD"`. Falls back
    /// to `"Untitled"` when DiskArbitration has no description for it.
    let volumeName: String

    /// Mount point URL, e.g. `file:///Volumes/My%20External%20SSD/`.
    /// Always present for drives published by `DriveMonitor`, which
    /// filters out unmounted entries.
    let mountPoint: URL

    var bsdName: String { id }
}
