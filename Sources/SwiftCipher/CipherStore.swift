import SwiftData
import SQLiteDB
import Foundation

public final class CipherStore: DataStore {
    public typealias Configuration = CipherConfiguration
    public typealias Snapshot = DefaultSnapshot

    public let identifier: String
    public let schema: Schema
    public let configuration: CipherConfiguration

    nonisolated(unsafe) private let db: Connection

    public required init(_ configuration: CipherConfiguration, migrationPlan: (any SchemaMigrationPlan.Type)?) throws {
        self.configuration = configuration
        self.schema = configuration.schema ?? Schema()
        self.identifier = configuration.name

        let path: String
        if let url = configuration.storeURL {
            path = url.path
        } else {
            let appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            path = appSupport.appendingPathComponent("\(configuration.name).store").path
        }

        let connection = try Connection(.uri(path))

        do {
            switch configuration.encryptionKey {
            case .passphrase(let s):
                try connection.key(s)
            case .raw(let data):
                try connection.key(Blob(bytes: Array(data)))
            }
        } catch {
            throw CipherError.encryptionFailed("invalid key")
        }

        do {
            _ = try connection.scalar("SELECT count(*) FROM sqlite_master;")
        } catch {
            throw CipherError.encryptionFailed("invalid key")
        }

        for entity in self.schema.entities {
            let name = entity.name
            try connection.execute("""
                CREATE TABLE IF NOT EXISTS "\(name)" (id TEXT PRIMARY KEY, data BLOB NOT NULL)
                """)
        }

        self.db = connection
    }

    public func fetch<T: PersistentModel>(_ request: DataStoreFetchRequest<T>) throws -> DataStoreFetchResult<T, DefaultSnapshot> {
        let entityName = Schema.entityName(for: T.self)
        let stmt = try db.prepare("""
            SELECT data FROM "\(entityName)"
            """)
        var snapshots: [DefaultSnapshot] = []
        let decoder = JSONDecoder()
        for row in stmt {
            if let blob = row[0] as? Blob {
                let data = Data(blob.bytes)
                let snapshot = try decoder.decode(DefaultSnapshot.self, from: data)
                snapshots.append(snapshot)
            }
        }
        return DataStoreFetchResult(
            descriptor: request.descriptor,
            fetchedSnapshots: snapshots,
            relatedSnapshots: [:]
        )
    }

    public func fetchCount<T: PersistentModel>(_ request: DataStoreFetchRequest<T>) throws -> Int {
        try fetch(request).fetchedSnapshots.count
    }

    public func fetchIdentifiers<T: PersistentModel>(_ request: DataStoreFetchRequest<T>) throws -> [PersistentIdentifier] {
        try fetch(request).fetchedSnapshots.map(\.persistentIdentifier)
    }

    public func save(_ request: DataStoreSaveChangesRequest<DefaultSnapshot>) throws -> DataStoreSaveChangesResult<DefaultSnapshot> {
        var remapped: [PersistentIdentifier: PersistentIdentifier] = [:]
        let encoder = JSONEncoder()

        for snapshot in request.inserted {
            let oldID = snapshot.persistentIdentifier
            let entityName = oldID.entityName
            let newPrimaryKey = UUID().uuidString
            let newID = try PersistentIdentifier.identifier(
                for: identifier,
                entityName: entityName,
                primaryKey: newPrimaryKey
            )
            remapped[oldID] = newID
            let remappedSnapshot = snapshot.copy(persistentIdentifier: newID, remappedIdentifiers: nil)
            let data = try encoder.encode(remappedSnapshot)
            let blob = Blob(bytes: Array(data))
            let rowKey = try rowID(for: newID, encoder: encoder)
            try db.run(
                """
                INSERT INTO "\(entityName)" (id, data) VALUES (?, ?)
                """,
                rowKey, blob
            )
        }

        for snapshot in request.updated {
            let id = snapshot.persistentIdentifier
            let entityName = id.entityName
            let rowKey = try rowID(for: id, encoder: encoder)
            let data = try encoder.encode(snapshot)
            let blob = Blob(bytes: Array(data))
            try db.run(
                """
                UPDATE "\(entityName)" SET data = ? WHERE id = ?
                """,
                blob, rowKey
            )
        }

        for snapshot in request.deleted {
            let id = snapshot.persistentIdentifier
            let entityName = id.entityName
            let rowKey = try rowID(for: id, encoder: encoder)
            try db.run(
                """
                DELETE FROM "\(entityName)" WHERE id = ?
                """,
                rowKey
            )
        }

        return DataStoreSaveChangesResult(
            for: identifier,
            remappedIdentifiers: remapped,
            snapshotsToReregister: [:]
        )
    }

    private func rowID(for persistentIdentifier: PersistentIdentifier, encoder: JSONEncoder) throws -> String {
        let data = try encoder.encode(persistentIdentifier)
        return String(decoding: data, as: UTF8.self)
    }

    public func rekey(to newKey: EncryptionKey) throws {
        try newKey.validate()
        do {
            switch newKey {
            case .passphrase(let s):
                try db.rekey(s)
            case .raw(let data):
                try db.rekey(Blob(bytes: Array(data)))
            }
        } catch {
            throw CipherError.encryptionFailed("rekey failed: \(error)")
        }
    }

    public func erase() throws {
        for entity in schema.entities {
            try db.run("""
                DELETE FROM "\(entity.name)"
                """)
        }
    }

    public func initializeState(for editingState: EditingState) {}

    public func invalidateState(for editingState: EditingState) {}

    public func cachedSnapshots(
        for persistentIdentifiers: [PersistentIdentifier],
        editingState: EditingState
    ) throws -> [PersistentIdentifier: DefaultSnapshot] {
        [:]
    }
}
