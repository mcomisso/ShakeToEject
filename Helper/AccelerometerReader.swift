import Foundation
import IOKit
import IOKit.hid

/// Reads raw accelerometer samples from the Apple SPU HID accelerometer
/// (Bosch BMI286 IMU) exposed via IOKit HID under `AppleSPUHIDDevice`.
///
/// Matching criteria (vendor ID, primary usage page, primary usage) were
/// derived from the M1 Pro probe in `docs/hardware-probe-m1pro.txt`.
///
/// **Thread safety:** The input report callback is invoked by the HID
/// subsystem on the thread that runs the CFRunLoop we schedule against.
/// The handler closure is declared `@Sendable`; the reader itself is
/// `@unchecked Sendable` because its only mutable state is the C callback
/// buffer, which is written only by the HID callback on a single thread.
///
/// **Privileges:** historically the SPU driver wake step required root.
/// On macOS 26 / M1 Pro we observed that `IORegistryEntrySetCFProperty`
/// on `AppleSPUHIDDriver` services succeeds from an unprivileged,
/// code-signed process — no `sudo` is necessary. If this ever regresses
/// and returns `kIOReturnNotPrivileged`, the SMAppService helper in
/// Phase 4 will satisfy the requirement.
final class AccelerometerReader: @unchecked Sendable {
    typealias SampleHandler = @Sendable (HIDReport) -> Void

    /// Apple's USB vendor ID, used to narrow HID matching.
    static let vendorIDApple = 1452
    /// Primary usage page of the Apple SPU HID IMU devices.
    static let primaryUsagePage = 0xFF00
    /// Primary usage of the accelerometer sub-device.
    static let primaryUsageAccelerometer = 3
    /// Oversized input report buffer (the spec is 22 bytes; we allocate
    /// extra headroom in case the driver ever bumps the report size).
    static let inputBufferSize = 64

    private let manager: IOHIDManager
    private let handler: SampleHandler
    private let buffer: UnsafeMutablePointer<UInt8>

    init(handler: @escaping SampleHandler) {
        self.manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.handler = handler
        self.buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.inputBufferSize)
        self.buffer.initialize(repeating: 0, count: Self.inputBufferSize)
    }

    deinit {
        buffer.deinitialize(count: Self.inputBufferSize)
        buffer.deallocate()
    }

    /// Opens the IOKit HID manager, locates the accelerometer device, and
    /// registers an input report callback. The callback runs on the CFRunLoop
    /// of the calling thread — the caller is responsible for running that
    /// run loop (e.g. via `CFRunLoopRun()`).
    ///
    /// Emits progress diagnostics to stderr so `--print` runs are observable
    /// even before the first sample arrives. These lines are prefixed with
    /// `[accel]` so they can be filtered out of downstream pipes with a
    /// simple `grep -v '^\[accel\]'`.
    func start() throws {
        // The SPU IMU driver boots in a low-power state and does not
        // deliver input reports until its sensor reporting/power state
        // properties are explicitly enabled. Without this wake step
        // everything downstream (enumerate, open, register callback,
        // schedule run loop) succeeds and yet zero samples arrive.
        // Reference: olvvier/apple-silicon-accelerometer's
        // `sensor_worker()` in `macimu/_spu.py`.
        wakeSPUDrivers()

        logDiagnostic("applying HID match {VendorID:\(Self.vendorIDApple), UsagePage:0x\(String(Self.primaryUsagePage, radix: 16)), Usage:\(Self.primaryUsageAccelerometer)}")
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: Self.vendorIDApple,
            kIOHIDPrimaryUsagePageKey as String: Self.primaryUsagePage,
            kIOHIDPrimaryUsageKey as String: Self.primaryUsageAccelerometer,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        logDiagnostic("opening IOHIDManager")
        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            throw AccelerometerReaderError.openFailed(ioReturn: openResult)
        }
        logDiagnostic("IOHIDManagerOpen succeeded")

        guard let devicesCF = IOHIDManagerCopyDevices(manager) else {
            throw AccelerometerReaderError.deviceNotFound
        }
        let devices = devicesCF as! Set<IOHIDDevice>
        logDiagnostic("IOHIDManagerCopyDevices returned \(devices.count) matching device(s)")
        if devices.isEmpty {
            throw AccelerometerReaderError.deviceNotFound
        }

        // The {VendorID:1452, UsagePage:0xFF00, Usage:3} criteria is not
        // specific enough on M1 Pro running macOS 26 — the Apple Internal
        // Keyboard/Trackpad reports the same combination for its own
        // private vendor page. The real accelerometer is identifiable by
        // its MaxInputReportSize of exactly `HIDReport.expectedSize` (22).
        let matchingReportSize = devices.filter { device in
            let size = (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int) ?? 0
            return size == HIDReport.expectedSize
        }
        logDiagnostic("filtered to \(matchingReportSize.count) device(s) with maxReportSize=\(HIDReport.expectedSize)")
        guard let device = matchingReportSize.first else {
            throw AccelerometerReaderError.deviceNotFound
        }

        let product = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "(anonymous)"
        logDiagnostic("selected device product=\"\(product)\"")

        // IOHIDManagerOpen claims matched devices at the manager level but
        // does NOT unconditionally open each underlying IOHIDDevice for
        // report delivery. An explicit IOHIDDeviceOpen is required before
        // the input report callback will fire on M1 Pro / macOS 26.
        let deviceOpenResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard deviceOpenResult == kIOReturnSuccess else {
            throw AccelerometerReaderError.openFailed(ioReturn: deviceOpenResult)
        }
        logDiagnostic("IOHIDDeviceOpen succeeded on selected device")

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device,
            buffer,
            CFIndex(Self.inputBufferSize),
            Self.inputReportCallback,
            selfPtr
        )
        logDiagnostic("registered input report callback (buffer: \(Self.inputBufferSize) bytes)")

        IOHIDDeviceScheduleWithRunLoop(
            device,
            CFRunLoopGetCurrent(),
            CFRunLoopMode.defaultMode.rawValue
        )
        logDiagnostic("scheduled device on CFRunLoop")

        IOHIDManagerScheduleWithRunLoop(
            manager,
            CFRunLoopGetCurrent(),
            CFRunLoopMode.defaultMode.rawValue
        )
        logDiagnostic("scheduled with CFRunLoop, waiting for samples")
    }

    private func logDiagnostic(_ message: String) {
        FileHandle.standardError.write(Data("[accel] \(message)\n".utf8))
    }

    /// Wakes every `AppleSPUHIDDriver` instance by setting its sensor
    /// reporting/power properties and its requested report interval.
    /// This is the operation that unlocks sample delivery. Verified to
    /// work unprivileged on macOS 26 / M1 Pro.
    private func wakeSPUDrivers() {
        let matching = IOServiceMatching("AppleSPUHIDDriver")
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard kr == KERN_SUCCESS else {
            logDiagnostic("wakeSPUDrivers: IOServiceGetMatchingServices failed 0x\(String(kr, radix: 16))")
            return
        }
        defer { IOObjectRelease(iterator) }

        let properties: [(String, Int32)] = [
            ("SensorPropertyReportingState", 1),
            ("SensorPropertyPowerState", 1),
            ("ReportInterval", 1000), // microseconds — 1000 μs = ~1 kHz native
        ]

        var wokenCount = 0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            var setAny = false
            for (key, value) in properties {
                let number = NSNumber(value: value)
                let result = IORegistryEntrySetCFProperty(service, key as CFString, number)
                if result == KERN_SUCCESS {
                    setAny = true
                } else {
                    logDiagnostic("wakeSPUDrivers: failed to set \(key)=\(value): 0x\(String(result, radix: 16))")
                }
            }
            if setAny { wokenCount += 1 }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        logDiagnostic("wakeSPUDrivers: woke \(wokenCount) AppleSPUHIDDriver instance(s)")
    }

    /// Unschedules from the run loop and closes the HID manager. Safe to
    /// call multiple times.
    func stop() {
        IOHIDManagerUnscheduleFromRunLoop(
            manager,
            CFRunLoopGetCurrent(),
            CFRunLoopMode.defaultMode.rawValue
        )
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    // MARK: - C callback bridge

    /// The @convention(c) callback invoked by IOKit HID when a new input
    /// report arrives. It reconstructs `self` from the context pointer and
    /// forwards parsed samples to the handler.
    private static let inputReportCallback: IOHIDReportCallback = {
        context, _, _, _, _, reportBytes, reportLength in
        guard let context else { return }
        let reader = Unmanaged<AccelerometerReader>.fromOpaque(context).takeUnretainedValue()
        let buffer = UnsafeRawBufferPointer(
            start: UnsafeRawPointer(reportBytes),
            count: reportLength
        )
        if let sample = HIDReport.parse(buffer) {
            reader.handler(sample)
        }
    }
}

enum AccelerometerReaderError: Error, CustomStringConvertible {
    case openFailed(ioReturn: IOReturn)
    case deviceNotFound

    var description: String {
        switch self {
        case .openFailed(let ioReturn):
            let hex = String(ioReturn, radix: 16, uppercase: true)
            if ioReturn == kIOReturnNotPrivileged {
                return "IOHIDManagerOpen failed: kIOReturnNotPrivileged (0x\(hex)) — run with sudo."
            }
            return "IOHIDManagerOpen failed with IOReturn 0x\(hex)."
        case .deviceNotFound:
            return "Accelerometer device not found. Verify hardware with `ioreg -l -w0 | grep -A5 AppleSPUHIDDevice`."
        }
    }
}
