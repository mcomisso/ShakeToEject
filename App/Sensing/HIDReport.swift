import Foundation

/// A single accelerometer sample decoded from a 22-byte HID input report
/// produced by the Apple SPU HID accelerometer (Bosch BMI286 IMU).
///
/// The report layout is undocumented by Apple. The format used here was
/// reverse-engineered by `olvvier/apple-silicon-accelerometer` and confirmed
/// against the M1 Pro report descriptor captured in
/// `docs/hardware-probe-m1pro.txt`.
///
/// Each axis is a signed Int32 in little-endian order. The raw integer is
/// divided by `0x10000` (65536) to yield a floating-point value in g.
struct HIDReport: Equatable {
    static let expectedSize = 22
    static let xOffset = 6
    static let yOffset = 10
    static let zOffset = 14
    static let rawScale: Double = 65536.0

    let x: Double
    let y: Double
    let z: Double

    /// Parses a raw HID input report into a sample. Returns `nil` if the
    /// buffer is shorter than `expectedSize`.
    ///
    /// The buffer may be longer than 22 bytes (callers should pass the
    /// entire buffer they received from the HID callback) — extra bytes
    /// after the z-axis are ignored.
    static func parse(_ bytes: UnsafeRawBufferPointer) -> HIDReport? {
        guard bytes.count >= expectedSize, let base = bytes.baseAddress else {
            return nil
        }
        let xRaw = Int32(littleEndian: base.loadUnaligned(fromByteOffset: xOffset, as: Int32.self))
        let yRaw = Int32(littleEndian: base.loadUnaligned(fromByteOffset: yOffset, as: Int32.self))
        let zRaw = Int32(littleEndian: base.loadUnaligned(fromByteOffset: zOffset, as: Int32.self))
        return HIDReport(
            x: Double(xRaw) / rawScale,
            y: Double(yRaw) / rawScale,
            z: Double(zRaw) / rawScale
        )
    }
}
