import Foundation

public enum SwiftCipher {
    /// Returns the URL of the named encrypted store in Application Support.
    /// Matches the default path used by `CipherContainer.makeContainer` when no `storeURL` is given.
    public static func defaultStoreURL(named name: String = "default") throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport.appendingPathComponent("\(name).store")
    }
}
