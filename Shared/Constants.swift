import Foundation

public enum Constants {
    public static let appBundleID = "com.mcsoftware.ShakeToEject"
    public static let helperBundleID = "com.mcsoftware.ShakeToEject.Helper"

    // Intentionally the same string as helperBundleID — the Mach service name
    // declared in the launchd plist's MachServices dict matches the helper's
    // bundle ID by convention. Keep them as distinct constants so callers
    // document intent (XPC lookup vs bundle identification).
    public static let helperMachServiceName = "com.mcsoftware.ShakeToEject.Helper"

    public static let helperPlistName = "com.mcsoftware.ShakeToEject.Helper.plist"

    // Used by the app's post-build embed script to locate the helper binary
    // inside Contents/MacOS/, and by SMAppService registration in Phase 4.
    // Unused in Phase 0 — do not remove.
    public static let helperExecutableName = "com.mcsoftware.ShakeToEject.Helper"
}
