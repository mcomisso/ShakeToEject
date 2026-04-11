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
/// **Three callbacks, not two.** We listen for `disk appeared`,
/// `disk disappeared`, AND `disk description changed` (filtered to
/// `kDADiskDescriptionVolumePathKey`). The third one is essential
/// for physical drive plug-ins: the kernel emits `appeared` as soon
/// as it sees the block device, which is *before* macOS has mounted
/// the filesystem. At that moment `VolumePath` is nil and the drive
/// is filtered out. The mount happens milliseconds later and fires
/// `description changed` — if we don't listen for that, we miss the
/// drive entirely. App launches only work "the first time" because
/// DiskArbitration replays `appeared` for already-mounted drives
/// with the full description including the mount point, masking the
/// bug for that initial call.
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
    /// disappear / description-changed callbacks. Safe to call
    /// multiple times — subsequent calls are no-ops.
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

        // Listen for volume-path changes so we catch drives that
        // appear unmounted and then get mounted by macOS a moment
        // later (the common case for physical plug-ins), and also
        // the reverse (drives that are unmounted by the user while
        // still connected).
        let watchedKeys = [kDADiskDescriptionVolumePathKey] as CFArray
        DARegisterDiskDescriptionChangedCallback(
            newSession,
            nil,
            watchedKeys,
            Self.diskDescriptionChangedCallback,
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

    /// Unmounts and ejects an explicit subset of drives. Used by
    /// the shake-triggered flow and the menu bar's Eject All
    /// button so they can filter out excluded drives before
    /// telling the monitor to eject.
    func eject(_ drivesToEject: [DriveInfo]) {
        NSLog("[drives] eject(\(drivesToEject.count) drive(s))")
        for drive in drivesToEject {
            guard let disk = disksByBSDName[drive.id] else { continue }
            DriveEjector.unmountAndEject(disk)
        }
    }

    // MARK: - C callback bridges

    private static let diskAppearedCallback: DADiskAppearedCallback = { disk, context in
        guard let context else { return }
        let monitor = Unmanaged<DriveMonitor>.fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated {
            monitor.reconcile(disk)
        }
    }

    private static let diskDisappearedCallback: DADiskDisappearedCallback = { disk, context in
        guard let context else { return }
        let monitor = Unmanaged<DriveMonitor>.fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated {
            monitor.handleDiskDisappeared(disk)
        }
    }

    private static let diskDescriptionChangedCallback: DADiskDescriptionChangedCallback = { disk, _, context in
        guard let context else { return }
        let monitor = Unmanaged<DriveMonitor>.fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated {
            monitor.reconcile(disk)
        }
    }

    // MARK: - Main-actor handlers

    /// Re-inspects a disk and updates our tracking to match its
    /// current state. Called by both the `appeared` callback (first
    /// time we see the disk) and the `description-changed` callback
    /// (state changed, e.g. mount point added or removed). Idempotent.
    private func reconcile(_ disk: DADisk) {
        guard let bsdNameCStr = DADiskGetBSDName(disk) else { return }
        let bsdName = String(cString: bsdNameCStr)

        guard let descriptionCF = DADiskCopyDescription(disk) else { return }
        let description = descriptionCF as NSDictionary

        let isInternal = (description[kDADiskDescriptionDeviceInternalKey] as? NSNumber)?.boolValue ?? true
        let mountPoint = description[kDADiskDescriptionVolumePathKey] as? URL

        let eligible = !isInternal && mountPoint != nil

        if eligible, let mountPoint {
            let volumeName = (description[kDADiskDescriptionVolumeNameKey] as? String) ?? "Untitled"
            let info = DriveInfo(
                id: bsdName,
                volumeName: volumeName,
                mountPoint: mountPoint
            )

            disksByBSDName[bsdName] = disk
            if let existingIndex = drives.firstIndex(where: { $0.id == bsdName }) {
                if drives[existingIndex] != info {
                    drives[existingIndex] = info
                    NSLog("[drives] updated: \(bsdName) \"\(volumeName)\" at \(mountPoint.path)")
                }
            } else {
                drives.append(info)
                NSLog("[drives] added: \(bsdName) \"\(volumeName)\" at \(mountPoint.path)")
            }
        } else {
            // Disk exists but isn't a drive we care about, OR it used
            // to be eligible and just got unmounted while still
            // connected. Either way, make sure it's not in our list.
            if disksByBSDName.removeValue(forKey: bsdName) != nil {
                drives.removeAll { $0.id == bsdName }
                NSLog("[drives] removed (unmounted or ineligible): \(bsdName)")
            }
        }
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
