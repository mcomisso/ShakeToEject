import Testing
import Foundation

struct HIDReportTests {
    // MARK: - Helpers

    /// Builds a 22-byte HID report with explicit int32 little-endian values at
    /// the documented offsets. Non-axis bytes are zero-filled.
    private func makeReport(x: Int32, y: Int32, z: Int32) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: HIDReport.expectedSize)
        writeInt32LE(x, into: &bytes, at: HIDReport.xOffset)
        writeInt32LE(y, into: &bytes, at: HIDReport.yOffset)
        writeInt32LE(z, into: &bytes, at: HIDReport.zOffset)
        return bytes
    }

    private func writeInt32LE(_ value: Int32, into bytes: inout [UInt8], at offset: Int) {
        let unsigned = UInt32(bitPattern: value)
        bytes[offset]     = UInt8(unsigned & 0xFF)
        bytes[offset + 1] = UInt8((unsigned >> 8) & 0xFF)
        bytes[offset + 2] = UInt8((unsigned >> 16) & 0xFF)
        bytes[offset + 3] = UInt8((unsigned >> 24) & 0xFF)
    }

    private func parse(_ bytes: [UInt8]) -> HIDReport? {
        bytes.withUnsafeBytes { HIDReport.parse($0) }
    }

    // MARK: - Tests

    @Test("Parses an all-zero report to zero acceleration on every axis")
    func parsesZeros() throws {
        let report = try #require(parse(makeReport(x: 0, y: 0, z: 0)))
        #expect(report.x == 0)
        #expect(report.y == 0)
        #expect(report.z == 0)
    }

    @Test("Parses a 1g value on the z axis (laptop sitting flat)")
    func parsesOneGOnZ() throws {
        // 1.0g == raw 65536
        let report = try #require(parse(makeReport(x: 0, y: 0, z: 65536)))
        #expect(report.x == 0)
        #expect(report.y == 0)
        #expect(report.z == 1.0)
    }

    @Test("Parses a -1g value on the z axis (laptop lid face down)")
    func parsesNegativeOneGOnZ() throws {
        let report = try #require(parse(makeReport(x: 0, y: 0, z: -65536)))
        #expect(report.z == -1.0)
    }

    @Test("Parses fractional g values correctly")
    func parsesFractionalG() throws {
        // 0.5g == raw 32768
        let report = try #require(parse(makeReport(x: 32768, y: -32768, z: 16384)))
        #expect(report.x == 0.5)
        #expect(report.y == -0.5)
        #expect(report.z == 0.25)
    }

    @Test("Parses extreme int32 values without overflow")
    func parsesExtremes() throws {
        let report = try #require(parse(makeReport(x: .max, y: .min, z: 0)))
        #expect(report.x == Double(Int32.max) / HIDReport.rawScale)
        #expect(report.y == Double(Int32.min) / HIDReport.rawScale)
        #expect(report.z == 0)
    }

    @Test("Returns nil for a buffer shorter than expectedSize")
    func rejectsShortBuffer() {
        let tooShort = [UInt8](repeating: 0, count: HIDReport.expectedSize - 1)
        #expect(parse(tooShort) == nil)
    }

    @Test("Returns nil for an empty buffer")
    func rejectsEmptyBuffer() {
        #expect(parse([]) == nil)
    }

    @Test("Accepts a buffer longer than expectedSize and ignores trailing bytes")
    func acceptsLongBuffer() throws {
        var bytes = makeReport(x: 0, y: 0, z: 65536)
        bytes.append(contentsOf: [0xDE, 0xAD, 0xBE, 0xEF])
        let report = try #require(parse(bytes))
        #expect(report.z == 1.0)
    }

    @Test("Zero-fills ignored bytes at offsets 0-5 and 18-21 without corrupting axes")
    func ignoresNonAxisBytes() throws {
        var bytes = makeReport(x: 0, y: 0, z: 65536)
        // Scribble on every byte that is NOT an axis slot
        for i in 0..<HIDReport.xOffset {
            bytes[i] = 0xAA
        }
        for i in (HIDReport.zOffset + 4)..<HIDReport.expectedSize {
            bytes[i] = 0x55
        }
        let report = try #require(parse(bytes))
        #expect(report.x == 0)
        #expect(report.y == 0)
        #expect(report.z == 1.0)
    }

    @Test("HIDReport.expectedSize matches the M1 Pro hardware report descriptor")
    func expectedSizeMatchesHardware() {
        // The probe in docs/hardware-probe-m1pro.txt shows
        // MaxInputReportSize = 22 for the accelerometer device.
        #expect(HIDReport.expectedSize == 22)
    }
}
