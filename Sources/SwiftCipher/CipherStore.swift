import SwiftData
import SQLiteDB
import Foundation

/// A SwiftData `DataStore` that keeps each entity in its own SQLCipher-encrypted table,
/// one column per attribute.
public final class CipherStore: DataStore {
    public typealias Configuration = CipherConfiguration
    public typealias Snapshot = DefaultSnapshot

    public let identifier: String
    public let schema: Schema
    public let configuration: CipherConfiguration

    /// SwiftData calls a store from any context's thread; all access goes through `lock`.
    nonisolated(unsafe) private let db: Connection
    private let lock = NSLock()
    private let tables: [String: EntityTable]
    private let codec: RowCodec

    public required init(_ configuration: CipherConfiguration, migrationPlan: (any SchemaMigrationPlan.Type)?) throws {
        self.configuration = configuration
        self.schema = configuration.schema ?? Schema()
        self.identifier = configuration.name
        self.codec = RowCodec(storeIdentifier: configuration.name)

        var tables: [String: EntityTable] = [:]
        for entity in schema.entities {
            tables[entity.name] = try EntityTable(entity, in: schema)
        }
        self.tables = tables

        let url = try configuration.resolvedStoreURL()
        let connection = try Connection(.uri(url.path))
        try Self.unlock(connection, with: configuration.encryptionKey)
        connection.busyTimeout = 5
        try connection.execute("PRAGMA journal_mode = WAL")
        try connection.transaction(.immediate) {
            for table in tables.values {
                for sql in table.createStatements { try connection.execute(sql) }
            }
        }
        self.db = connection
    }

    static func unlock(_ connection: Connection, with key: EncryptionKey) throws {
        do {
            switch key {
            case .passphrase(let s): try connection.key(s)
            case .raw(let data): try connection.key(Blob(bytes: Array(data)))
            }
            _ = try connection.scalar("SELECT count(*) FROM sqlite_master")
        } catch {
            throw CipherError.encryptionFailed("invalid key")
        }
    }

    private func layout(_ name: String) throws -> EntityTable {
        guard let table = tables[name] else {
            throw CipherError.unsupportedSchema("\(name) is not part of this store's schema")
        }
        return table
    }

    // MARK: - Fetch

    public func fetch<T: PersistentModel>(_ request: DataStoreFetchRequest<T>) throws -> DataStoreFetchResult<T, DefaultSnapshot> {
        let table = try layout(Schema.entityName(for: T.self))
        let tail = try queryTail(request.descriptor)
        let snapshots = try lock.withLock {
            try readRows(of: table, tail: tail)
        }
        return DataStoreFetchResult(descriptor: request.descriptor, fetchedSnapshots: snapshots)
    }

    public func fetchCount<T: PersistentModel>(_ request: DataStoreFetchRequest<T>) throws -> Int {
        let table = try layout(Schema.entityName(for: T.self))
        let tail = try queryTail(request.descriptor)
        return try lock.withLock {
            let count = try db.scalar("SELECT count(*) FROM (SELECT 1 FROM \(q(table.name))\(tail))") as? Int64
            return Int(count ?? 0)
        }
    }

    public func fetchIdentifiers<T: PersistentModel>(_ request: DataStoreFetchRequest<T>) throws -> [PersistentIdentifier] {
        let table = try layout(Schema.entityName(for: T.self))
        let tail = try queryTail(request.descriptor)
        return try lock.withLock {
            try db.prepare("SELECT \(q(EntityTable.primaryKey)) FROM \(q(table.name))\(tail)").map { row in
                try codec.identifier(entity: table.name, primaryKey: row[0] as! String)
            }
        }
    }

    /// ORDER BY / LIMIT / OFFSET for a descriptor. Predicates and sorts are handed back to
    /// SwiftData to evaluate in memory until the SQL translator supports them.
    private func queryTail<T>(_ descriptor: FetchDescriptor<T>) throws -> String {
        if descriptor.predicate != nil { throw DataStoreError.preferInMemoryFilter }
        if !descriptor.sortBy.isEmpty { throw DataStoreError.preferInMemorySort }
        var sql = " ORDER BY rowid"
        if let limit = descriptor.fetchLimit { sql += " LIMIT \(limit)" }
        if let offset = descriptor.fetchOffset { sql += (descriptor.fetchLimit == nil ? " LIMIT -1" : "") + " OFFSET \(offset)" }
        return sql
    }

    private func readRows(of table: EntityTable, tail: String) throws -> [DefaultSnapshot] {
        let toOne = table.toOne.keys.sorted()
        let columns = [EntityTable.primaryKey] + table.attributes.map(\.name) + toOne
        let statement = try db.prepare("SELECT \(columns.map(q).joined(separator: ", ")) FROM \(q(table.name))\(tail)")

        var snapshots: [DefaultSnapshot] = []
        for row in statement {
            let pk = row[0] as! String
            var object: [String: Any] = ["persistentIdentifier": try codec.encodedIdentifier(entity: table.name, primaryKey: pk)]
            for (i, attribute) in table.attributes.enumerated() {
                object[attribute.name] = try codec.value(from: row[1 + i], kind: attribute.kind)
            }
            for (i, name) in toOne.enumerated() {
                let target = row[1 + table.attributes.count + i] as? String
                object[name] = try target.map { try codec.encodedIdentifier(entity: table.toOne[name]!, primaryKey: $0) } ?? NSNull()
            }
            for (name, link) in table.derivedToMany {
                // shortcut: one query per row and relationship; batch with IN (...) if large lists get slow.
                let keys = try db.prepare(
                    "SELECT \(q(EntityTable.primaryKey)) FROM \(q(link.destination)) WHERE \(q(link.inverse)) = ? ORDER BY rowid", pk
                ).map { $0[0] as! String }
                object[name] = try keys.map { try codec.encodedIdentifier(entity: link.destination, primaryKey: $0) }
            }
            for join in table.joinTables {
                let keys = try db.prepare("SELECT target FROM \(q(join.table)) WHERE owner = ? ORDER BY rowid", pk).map { $0[0] as! String }
                object[join.relationship] = try keys.map { try codec.encodedIdentifier(entity: join.destination, primaryKey: $0) }
            }
            snapshots.append(try codec.snapshot(from: object))
        }
        return snapshots
    }

    // MARK: - Save

    public func save(_ request: DataStoreSaveChangesRequest<DefaultSnapshot>) throws -> DataStoreSaveChangesResult<DefaultSnapshot> {
        try lock.withLock {
            var remapped: [PersistentIdentifier: PersistentIdentifier] = [:]
            // Temporary key → stored key. They differ only when a unique constraint merged an insert into an existing row.
            var keyMap: [String: String] = [:]

            try db.transaction(.immediate) {
                var pending: [(EntityTable, String, [String: Any])] = []
                for snapshot in request.inserted {
                    let id = snapshot.persistentIdentifier
                    let table = try layout(id.entityName)
                    let object = try codec.object(from: snapshot)
                    guard let temporaryKey = codec.primaryKey(ofEncodedIdentifier: object["persistentIdentifier"]) else {
                        throw CipherError.storeCorrupted("inserted snapshot has no primary key")
                    }
                    let key = try existingRow(in: table, matching: object) ?? temporaryKey
                    keyMap[temporaryKey] = key
                    remapped[id] = try codec.identifier(entity: table.name, primaryKey: key)
                    pending.append((table, key, object))
                }
                for (table, key, object) in pending {
                    try write(object, key: key, to: table, keyMap: keyMap)
                }

                for snapshot in request.updated {
                    let table = try layout(snapshot.persistentIdentifier.entityName)
                    let object = try codec.object(from: snapshot)
                    guard let key = codec.primaryKey(ofEncodedIdentifier: object["persistentIdentifier"]) else {
                        throw CipherError.storeCorrupted("updated snapshot has no primary key")
                    }
                    try write(object, key: key, to: table, keyMap: keyMap)
                }

                for snapshot in request.deleted {
                    let table = try layout(snapshot.persistentIdentifier.entityName)
                    let object = try codec.object(from: snapshot)
                    guard let key = codec.primaryKey(ofEncodedIdentifier: object["persistentIdentifier"]) else { continue }
                    try deleteRow(key, from: table)
                }
            }
            return DataStoreSaveChangesResult(for: identifier, remappedIdentifiers: remapped)
        }
    }

    /// Primary key of the row an insert must merge into because it shares a unique value,
    /// matching how the default SwiftData store upserts on `@Attribute(.unique)`.
    private func existingRow(in table: EntityTable, matching object: [String: Any]) throws -> String? {
        for constraint in table.uniqueConstraints {
            var clauses: [String] = []
            var bindings: [Binding?] = []
            for name in constraint {
                guard let attribute = table.attributes.first(where: { $0.name == name }) else { continue }
                let binding = try codec.binding(for: object[name], kind: attribute.kind)
                clauses.append(binding == nil ? "\(q(name)) IS NULL" : "\(q(name)) = ?")
                if let binding { bindings.append(binding) }
            }
            guard !clauses.isEmpty else { continue }
            let sql = "SELECT \(q(EntityTable.primaryKey)) FROM \(q(table.name)) WHERE \(clauses.joined(separator: " AND ")) LIMIT 1"
            if let key = try db.scalar(sql, bindings) as? String { return key }
        }
        return nil
    }

    private func write(_ object: [String: Any], key: String, to table: EntityTable, keyMap: [String: String]) throws {
        let toOne = table.toOne.keys.sorted()
        let columns = [EntityTable.primaryKey] + table.attributes.map(\.name) + toOne
        var bindings: [Binding?] = [key]
        for attribute in table.attributes {
            bindings.append(try codec.binding(for: object[attribute.name], kind: attribute.kind))
        }
        for name in toOne {
            bindings.append(codec.primaryKey(ofEncodedIdentifier: object[name]).map { keyMap[$0] ?? $0 })
        }
        let updates = columns.dropFirst().map { "\(q($0)) = excluded.\(q($0))" }
        try db.run("""
            INSERT INTO \(q(table.name)) (\(columns.map(q).joined(separator: ", ")))
            VALUES (\(Array(repeating: "?", count: columns.count).joined(separator: ", ")))
            ON CONFLICT (\(q(EntityTable.primaryKey))) DO \(updates.isEmpty ? "NOTHING" : "UPDATE SET " + updates.joined(separator: ", "))
            """, bindings)

        for join in table.joinTables {
            try db.run("DELETE FROM \(q(join.table)) WHERE owner = ?", key)
            for target in (object[join.relationship] as? [Any] ?? []) {
                guard let targetKey = codec.primaryKey(ofEncodedIdentifier: target) else { continue }
                try db.run("INSERT OR IGNORE INTO \(q(join.table)) (owner, target) VALUES (?, ?)", key, keyMap[targetKey] ?? targetKey)
            }
        }
    }

    /// Deletes a row and every reference to it, so no other row is left pointing at a
    /// model that no longer exists (SwiftData invalidates such models on access).
    private func deleteRow(_ key: String, from table: EntityTable) throws {
        try db.run("DELETE FROM \(q(table.name)) WHERE \(q(EntityTable.primaryKey)) = ?", key)
        for join in table.joinTables {
            try db.run("DELETE FROM \(q(join.table)) WHERE owner = ?", key)
        }
        for other in tables.values {
            for (column, destination) in other.toOne where destination == table.name {
                try db.run("UPDATE \(q(other.name)) SET \(q(column)) = NULL WHERE \(q(column)) = ?", key)
            }
            for join in other.joinTables where join.destination == table.name {
                try db.run("DELETE FROM \(q(join.table)) WHERE target = ?", key)
            }
        }
    }

    // MARK: - Maintenance

    public func rekey(to newKey: EncryptionKey) throws {
        try newKey.validate()
        try lock.withLock {
            do {
                switch newKey {
                case .passphrase(let s): try db.rekey(s)
                case .raw(let data): try db.rekey(Blob(bytes: Array(data)))
                }
            } catch {
                throw CipherError.encryptionFailed("rekey failed: \(error)")
            }
        }
    }

    public func erase() throws {
        try lock.withLock {
            try db.transaction(.immediate) {
                for table in tables.values {
                    try db.run("DELETE FROM \(q(table.name))")
                    for join in table.joinTables { try db.run("DELETE FROM \(q(join.table))") }
                }
            }
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
