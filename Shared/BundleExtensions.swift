import Foundation

public extension Bundle {
    /// User-visible app name. Single source of truth — reads the
    /// `CFBundleDisplayName` injected by `project.yml`. The codebase
    /// identifier (module, bundle ID, scheme) remains `ShakeToEject`
    /// even as the marketing name evolves.
    var displayName: String {
        (object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String)
            ?? "Grab to Eject"
    }
}
