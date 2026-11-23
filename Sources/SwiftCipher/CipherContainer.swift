import SwiftData
import SQLiteDB
import Foundation

public enum CipherContainer {
    /// A `ModelContainer` backed by one encrypted store holding `models`.
    public static func makeContainer(
        for models: [any PersistentModel.Type],
        encryptionKey: EncryptionKey? = nil,
        name: String = "default",
        storeURL: URL? = nil,
        appGroup: String? = nil,
        migrationPlan: (any SchemaMigrationPlan.Type)? = nil
    ) throws -> ModelContainer {
        try makeContainer(
            for: Schema(models),
            encryptionKey: encryptionKey,
            name: name,
            storeURL: storeURL,
            appGroup: appGroup,
            migrationPlan: migrationPlan
        )
    }

    /// A `ModelContainer` backed by one encrypted store.
    ///
    /// Equivalent to `ModelContainer(for: schema, configurations: CipherConfiguration(...))`.
    public static func makeContainer(
        for schema: Schema,
        encryptionKey: EncryptionKey? = nil,
        name: String = "default",
        storeURL: URL? = nil,
        appGroup: String? = nil,
        migrationPlan: (any SchemaMigrationPlan.Type)? = nil
    ) throws -> ModelContainer {
        let configuration = CipherConfiguration(
            name: name,
            schema: schema,
            encryptionKey: encryptionKey,
            storeURL: storeURL,
            appGroup: appGroup,
            migrationPlan: migrationPlan
        )
        return try makeContainer(for: schema, configurations: [configuration])
    }

    /// A `ModelContainer` backed by several encrypted stores. Every configuration is
    /// validated before any file is opened.
    public static func makeContainer(
        for schema: Schema,
        configurations: [CipherConfiguration]
    ) throws -> ModelContainer {
        for configuration in configurations {
            try configuration.validate()
        }
        return try ModelContainer(for: schema, configurations: configurations)
    }

    /// Re-encrypts the store file at `url` with a new key. Close every container using the
    /// store first; afterwards, open it with `newKey`. A `.keychain` key that does not exist
    /// yet is created.
    public static func rekey(storeAt url: URL, from oldKey: EncryptionKey, to newKey: EncryptionKey) throws {
        let old = try oldKey.resolved()
        let new = try newKey.resolved(createIfMissing: true)
        let connection = try Connection(.uri(url.path))
        try CipherStore.unlock(connection, with: old)
        do {
            try new.rekey(connection)
        } catch {
            throw CipherError.encryptionFailed("rekey failed: \(error)")
        }
    }
}
