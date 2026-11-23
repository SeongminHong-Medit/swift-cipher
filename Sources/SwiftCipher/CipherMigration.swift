import Foundation
import SQLiteDB
import SwiftData

// MARK: - CipherMigration

public enum CipherMigration {
    /// Encrypts an existing plaintext SQLite database in-place.
    /// The original file at `url` is replaced with an encrypted version.
    /// A temporary file is used during conversion; cleaned up on success or failure.
    public static func encrypt(
        fileAt url: URL,
        using encryptionKey: EncryptionKey
    ) throws {
        let key = try encryptionKey.resolved(createIfMissing: true)

        let tempPath = url.path + ".cipher_tmp"
        let tempURL = URL(fileURLWithPath: tempPath)

        // Ensure any leftover temp file from a prior failed run is removed first.
        try? FileManager.default.removeItem(at: tempURL)

        // Defer cleanup of the temp file on any exit path.
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        do {
            // Use a local scope so `db` is released (and the connection closed)
            // before we attempt to replace the file.
            try withExtendedLifetime(()) { _ in
                let db = try Connection(.uri(url.path))

                let attachSQL = "ATTACH DATABASE \(sqlLiteral(tempPath)) AS encrypted \(key.attachClause)"
                try db.execute(attachSQL)
                try db.execute("SELECT sqlcipher_export('encrypted')")
                try db.execute("DETACH DATABASE encrypted")
                // `db` goes out of scope here, closing the connection.
            }
        } catch {
            throw CipherError.migrationFailed("SQLCipher export failed: \(error)")
        }

        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } catch {
            throw CipherError.migrationFailed("File replacement failed: \(error)")
        }
    }

    /// Copies every model in an existing SwiftData store (the default, unencrypted kind)
    /// into the encrypted store described by `configuration`.
    ///
    /// - The source is opened read-only and never changed. Delete it yourself once the
    ///   import succeeded, for example with `removeSwiftDataStore(at:)`.
    /// - Everything is written in one transaction and row counts are checked before it
    ///   commits, so a failure or crash leaves the encrypted store unchanged.
    /// - Safe to call again: a store already imported from `sourceURL` returns `false`
    ///   without copying anything.
    ///
    /// - Parameter types: The model types, the same as for the source's `ModelContainer`.
    /// - Returns: `true` if rows were imported.
    @discardableResult
    public static func importSwiftDataStore(
        at sourceURL: URL,
        types: [any PersistentModel.Type],
        into configuration: CipherConfiguration
    ) throws -> Bool {
        let schema = Schema(types)
        var configuration = configuration
        configuration.schema = schema
        let destination = try CipherStore(configuration, migrationPlan: nil)

        let source: ModelContainer
        do {
            source = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: sourceURL, allowsSave: false)])
        } catch {
            throw CipherError.migrationFailed("could not open the SwiftData store at \(sourceURL.path): \(error)")
        }
        let context = ModelContext(source)

        var models: [any PersistentModel] = []
        for type in types {
            models += try fetchAll(type, in: context)
        }

        // Source identifiers → new primary keys, so relationships can be rewritten.
        var keys: [String: String] = [:]
        for model in models {
            keys[try canonical(model.persistentModelID)] = UUID().uuidString
        }

        var rows: [(entity: String, key: String, object: [String: Any])] = []
        for model in models {
            let data = try JSONEncoder().encode(snapshot(of: model))
            guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CipherError.migrationFailed("could not read a \(type(of: model))")
            }
            for (name, value) in object where name != "persistentIdentifier" {
                if let reference = value as? [String: Any], reference["implementation"] != nil {
                    object[name] = try remap(reference, keys)
                } else if let references = value as? [[String: Any]], references.allSatisfy({ $0["implementation"] != nil }), !references.isEmpty {
                    object[name] = try references.map { try remap($0, keys) }
                }
            }
            let entity = model.persistentModelID.entityName
            rows.append((entity, keys[try canonical(model.persistentModelID)]!, object))
        }

        do {
            return try destination.importRows(rows, marker: "imported:" + sourceURL.standardizedFileURL.path)
        } catch let error as CipherError {
            throw error
        } catch {
            throw CipherError.migrationFailed("\(error)")
        }
    }

    /// Deletes a SwiftData store file and its `-wal` and `-shm` companions.
    public static func removeSwiftDataStore(at url: URL) throws {
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
        }
    }

    private static func snapshot<T: PersistentModel>(of model: T) -> DefaultSnapshot {
        // Apple's store loads composite values and relationships lazily; a snapshot of an
        // unloaded property holds a placeholder, so read every property first.
        for keyPath in PropertyNames.keyPaths(of: T.self) {
            _ = model[keyPath: keyPath]
        }
        var related: [PersistentIdentifier: any BackingData] = [:]
        return DefaultSnapshot(from: model.persistentBackingData, relatedBackingDatas: &related)
    }

    private static func fetchAll<T: PersistentModel>(_ type: T.Type, in context: ModelContext) throws -> [any PersistentModel] {
        try context.fetch(FetchDescriptor<T>())
    }

    /// A stable string for an identifier, used to match references to their targets.
    private static func canonical(_ identifier: PersistentIdentifier) throws -> String {
        try canonical(JSONSerialization.jsonObject(with: JSONEncoder().encode(identifier)))
    }

    private static func canonical(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: .sortedKeys), as: UTF8.self)
    }

    /// The shape `CipherStore` reads a reference's primary key from.
    private static func remap(_ reference: [String: Any], _ keys: [String: String]) throws -> [String: Any] {
        guard let key = keys[try canonical(reference)] else {
            throw CipherError.migrationFailed("a relationship points to a model that is not in the source store")
        }
        return ["implementation": ["primaryKey": key]]
    }
}
