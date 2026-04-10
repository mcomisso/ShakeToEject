@preconcurrency import DiskArbitration
import Foundation

/// Stateless helper that unmounts and then ejects a single `DADisk`.
///
/// The operations are asynchronous via DiskArbitration's dissenter-
/// callback mechanism. This type is fire-and-forget: callers invoke
/// `unmountAndEject(_:)`, the drive starts shutting down, and when it
/// finishes disappearing it naturally leaves `DriveMonitor.drives` via
/// the `DARegisterDiskDisappearedCallback` path. Success/failure is
/// logged via `NSLog`.
///
/// The DiskArbitration callbacks fire on the same dispatch queue that
/// was set on the owning `DASession` (main, in our case). No actor
/// hopping is needed because the callbacks only log.
enum DriveEjector {
    /// Initiates an unmount followed by an eject for the given disk.
    /// Returns immediately; the work completes asynchronously.
    static func unmountAndEject(_ disk: DADisk) {
        let bsdName = Self.bsdName(of: disk)
        NSLog("[drives] unmounting \(bsdName)…")

        DADiskUnmount(
            disk,
            DADiskUnmountOptions(kDADiskUnmountOptionDefault),
            Self.unmountCallback,
            nil
        )
    }

    // MARK: - Callbacks

    private static let unmountCallback: DADiskUnmountCallback = { disk, dissenter, _ in
        let bsdName = Self.bsdName(of: disk)
        if let dissenter {
            let status = DADissenterGetStatus(dissenter)
            NSLog("[drives] unmount \(bsdName) DISSENTED status=0x\(String(status, radix: 16, uppercase: true))")
            return
        }
        NSLog("[drives] unmount \(bsdName) ok — ejecting…")
        DADiskEject(
            disk,
            DADiskEjectOptions(kDADiskEjectOptionDefault),
            Self.ejectCallback,
            nil
        )
    }

    private static let ejectCallback: DADiskEjectCallback = { disk, dissenter, _ in
        let bsdName = Self.bsdName(of: disk)
        if let dissenter {
            let status = DADissenterGetStatus(dissenter)
            NSLog("[drives] eject \(bsdName) DISSENTED status=0x\(String(status, radix: 16, uppercase: true))")
            return
        }
        NSLog("[drives] eject \(bsdName) ok")
    }

    // MARK: - Helpers

    private static func bsdName(of disk: DADisk) -> String {
        guard let cStr = DADiskGetBSDName(disk) else { return "(unknown)" }
        return String(cString: cStr)
    }
}
