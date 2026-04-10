@preconcurrency import DiskArbitration
import Foundation
import Observation

/// Observes DiskArbitration for external drive mount/unmount events and
/// publishes the current set of eligible drives as an `@Observable`
/// array that SwiftUI views can bind to directly.
///
/// **Eligibility** is defined as "not internal, and currently mounted":
/// the drive reports `kDADiskDescriptionDeviceInternalKey == false` and
/// its description contains a non-nil `kDADiskDescriptionVolumePathKey`.
/// This excludes the boot drive, internal SSDs, and any unmounted
/// slices that DiskArbitration surfaces.
///
/// **Threading:** the monitor sets its `DASession`'s dispatch queue to
/// `DispatchQueue.main`, so every DiskArbitration callback fires on the
/// main actor. The C callbacks use `MainActor.assumeIsolated` to
/// reach the main-actor-isolated handler methods without a `Task` hop.
/// `@preconcurrency import DiskArbitration` bridges the pre-Sendable
/// CFTypes (`DADisk`, `DASession`, `DADissenter`) into Swift 6 strict
/// concurrency.
@MainActor
@Observable
final class DriveMonitor {
    /// The current list of mounted external drives. Ordered by
    /// appearance (most-recently-mounted last). Mutated only by the
    /// DiskArbitration callbacks.
    private(set) var drives: [DriveInfo] = []

    private var session: DASession?
    private var disksByBSDName: [String: DADisk] = [:]

    /// Starts the DiskArbitration session and registers the appear /
    /// disappear callbacks. Safe to call multiple times — subsequent
    /// calls are no-ops.
    func start() {
        guard session == nil else { return }

        guard let newSession = DASessionCreate(kCFAllocatorDefault) else {
            NSLog("[drives] DASessionCreate failed — monitor inactive")
            return
        }
        session = newSession
        DASessionSetDispatchQueue(newSession, DispatchQueue.main)

        let context = Unmanaged.passUnretained(self).toOpaque()

        DARegisterDiskAppearedCallback(
            newSession,
            nil,
            Self.diskAppearedCallback,
            context
        )

        DARegisterDiskDisappearedCallback(
            newSession,
            nil,
            Self.diskDisappearedCallback,
            context
        )

        NSLog("[drives] DriveMonitor started")
    }

    /// Tears down the DiskArbitration session and clears the drive list.
    /// Safe to call multiple times.
    func stop() {
        if let s = session {
            DASessionSetDispatchQueue(s, nil)
        }
        session = nil
        disksByBSDName.removeAll()
        drives.removeAll()
        NSLog("[drives] DriveMonitor stopped")
    }

    /// Unmounts and ejects every drive currently in the list. Each
    /// drive is handled independently; a failure on one does not stop
    /// the others.
    func ejectAll() {
        let snapshot = Array(disksByBSDName.values)
        NSLog("[drives] ejectAll — \(snapshot.count) drive(s)")
        for disk in snapshot {
            DriveEjector.unmountAndEject(disk)
        }
    }

    // MARK: - C callback bridges

    private static let diskAppearedCallback: DADiskAppearedCallback = { disk, context in
        guard let context else { return }
        let monitor = Unmanaged<DriveMonitor>.fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated {
            monitor.handleDiskAppeared(disk)
        }
    }

    private static let diskDisappearedCallback: DADiskDisappearedCallback = { disk, context in
        guard let context else { return }
        let monitor = Unmanaged<DriveMonitor>.fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated {
            monitor.handleDiskDisappeared(disk)
        }
    }

    // MARK: - Main-actor handlers

    private func handleDiskAppeared(_ disk: DADisk) {
        guard let bsdNameCStr = DADiskGetBSDName(disk) else { return }
        let bsdName = String(cString: bsdNameCStr)

        guard let descriptionCF = DADiskCopyDescription(disk) else { return }
        let description = descriptionCF as NSDictionary

        let isInternal = (description[kDADiskDescriptionDeviceInternalKey] as? NSNumber)?.boolValue ?? true
        guard !isInternal else { return }

        guard let mountPoint = description[kDADiskDescriptionVolumePathKey] as? URL else {
            // Not a mounted volume — could be the whole-disk entry
            // (e.g. disk4) that appears alongside its partition slices.
            // We only track mounted volumes.
            return
        }

        let volumeName = (description[kDADiskDescriptionVolumeNameKey] as? String) ?? "Untitled"

        let info = DriveInfo(
            id: bsdName,
            volumeName: volumeName,
            mountPoint: mountPoint
        )

        disksByBSDName[bsdName] = disk
        if let existingIndex = drives.firstIndex(where: { $0.id == bsdName }) {
            drives[existingIndex] = info
        } else {
            drives.append(info)
        }

        NSLog("[drives] appeared: \(bsdName) \"\(volumeName)\" at \(mountPoint.path)")
    }

    private func handleDiskDisappeared(_ disk: DADisk) {
        guard let bsdNameCStr = DADiskGetBSDName(disk) else { return }
        let bsdName = String(cString: bsdNameCStr)

        if disksByBSDName.removeValue(forKey: bsdName) != nil {
            drives.removeAll { $0.id == bsdName }
            NSLog("[drives] disappeared: \(bsdName)")
        }
    }
}
