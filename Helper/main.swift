import Foundation

// Phase 0: the helper only proves it exists and is embedded correctly.
// Phase 1 adds the IOKit HID reader. Phase 3 adds the XPC listener.

let version = "0.1.0"
let args = CommandLine.arguments.dropFirst()

if args.contains("--version") {
    print(version)
    exit(0)
}

FileHandle.standardError.write(Data("ShakeToEject helper \(version) — not yet implemented\n".utf8))
exit(0)
