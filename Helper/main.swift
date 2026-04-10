import Foundation

// Phase 1: the helper can open the accelerometer and stream samples to
// stdout for interactive verification. Phase 2 adds shake detection.
// Phase 3 replaces the CLI with an XPC listener.

let version = "0.1.0"
let args = Array(CommandLine.arguments.dropFirst())
let programName = (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? "helper"

func printUsage() {
    let usage = """
    ShakeToEject helper \(version)

    Usage:
      \(programName) --version    Print version and exit
      \(programName) --print      Stream accelerometer samples to stdout
                       (diagnostic lines go to stderr — pipe with 2>/dev/null to hide)

    """
    FileHandle.standardError.write(Data(usage.utf8))
}

if args.contains("--version") {
    print(version)
    exit(0)
}

if args.contains("--print") {
    let reader = AccelerometerReader { sample in
        let line = String(
            format: "%+.4f\t%+.4f\t%+.4f",
            sample.x, sample.y, sample.z
        )
        print(line)
        fflush(stdout)
    }

    do {
        try reader.start()
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }

    // Block until interrupted (Ctrl+C). The reader's callbacks fire on
    // this run loop.
    CFRunLoopRun()

    // CFRunLoopRun() only returns if the run loop is explicitly stopped,
    // which we do not do in --print mode. Unreachable in practice.
    reader.stop()
    exit(0)
}

printUsage()
exit(0)
