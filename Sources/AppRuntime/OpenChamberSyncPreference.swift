import Foundation

enum OpenChamberSyncPreference {
    static let enabledKey = "OpenChamberAutomaticSyncEnabled"
    static let defaultEnabled = true
    static let debounceInterval: TimeInterval = 1
    static let retryInterval: TimeInterval = 60
    static let captureGraceInterval: TimeInterval = 900
    static func enabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) == nil ? defaultEnabled : defaults.bool(forKey: enabledKey)
    }
}
