import SwiftData
import Foundation

/// Describes one encrypted store. Pass it to `ModelContainer` like a `ModelConfiguration`:
///
/// ```swift
/// let container = try ModelContainer(for: Note.self, configurations: CipherConfiguration())
/// ```
public struct CipherConfiguration: DataStoreConfiguration {
    public typealias Store = CipherStore

    public var name: String
    public var schema: Schema?
    public var encryptionKey: EncryptionKey
    /// The store file. When `nil`, the file is `<name>.store` in Application Support,
    /// inside the `appGroup` container when one is set.
    public var storeURL: URL?
    /// An App Group identifier, so app extensions can open the same store.
    public var appGroup: String?
    /// Migration stages for this store. `ModelContainer` passes no migration plan to custom
    /// stores, so it travels on the configuration instead.
    public var migrationPlan: (any SchemaMigrationPlan.Type)?

    /// - Parameter encryptionKey: Defaults to `.keychain(account: name)`, a random key kept in the Keychain.
    public init(
        name: String = "default",
        schema: Schema? = nil,
        encryptionKey: EncryptionKey? = nil,
        storeURL: URL? = nil,
        appGroup: String? = nil,
        migrationPlan: (any SchemaMigrationPlan.Type)? = nil
    ) {
        self.name = name
        self.schema = schema
        self.encryptionKey = encryptionKey ?? .keychain(account: name)
        self.storeURL = storeURL
        self.appGroup = appGroup
        self.migrationPlan = migrationPlan
    }

    func resolvedStoreURL() throws -> URL {
        if let storeURL { return storeURL }
        let base: URL
        if let appGroup {
            guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
                throw CipherError.unsupportedSchema("App Group \"\(appGroup)\" is not available. Add it to the app's entitlements.")
            }
            base = group.appendingPathComponent("Library/Application Support", isDirectory: true)
        } else {
            base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("\(name).store")
    }

    public func validate() throws {
        try encryptionKey.validate()
    }

    public static func == (lhs: CipherConfiguration, rhs: CipherConfiguration) -> Bool {
        lhs.name == rhs.name && lhs.storeURL == rhs.storeURL && lhs.appGroup == rhs.appGroup
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(storeURL)
        hasher.combine(appGroup)
    }
}
