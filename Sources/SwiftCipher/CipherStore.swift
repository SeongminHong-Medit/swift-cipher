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

        let tables = try SchemaMigrator.tables(of: schema)
        self.tables = tables

        let url = try configuration.resolvedStoreURL()
        let storeExists = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0) > 0
        let key = try configuration.encryptionKey.resolved(createIfMissing: !storeExists)
        if storeExists {
            try SchemaMigrator.migrate(
                url: url, key: key, schema: schema, configuration: configuration,
                plan: migrationPlan ?? configuration.migrationPlan
            )
        }
        let connection = try Connection(.uri(url.path))
        try Self.unlock(connection, with: key)
        connection.busyTimeout = 5
        try connection.execute("PRAGMA journal_mode = WAL")
        try connection.registerSwiftStringFunctions()
        try connection.transaction(.immediate) {
            try connection.execute("CREATE TABLE IF NOT EXISTS _meta (key TEXT PRIMARY KEY NOT NULL, value TEXT)")
            for table in tables.values {
                for sql in table.createStatements { try connection.execute(sql) }
            }
            try SchemaMigrator.recordSignature(SchemaMigrator.signature(of: tables), in: connection)
        }
        self.db = connection
    }

    /// Applies the key and checks it by reading the schema; SQLCipher only fails on first read.
    static func unlock(_ connection: Connection, with key: ResolvedKey) throws {
        do {
            try key.unlock(connection)
            _ = try connection.scalar("SELECT count(*) FROM sqlite_master")
        } catch {
            throw CipherError.wrongKey
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
        let snapshots = try lock.withLock {
            let query = try plan(request.descriptor, table: table, fallback: true)
            return try readRows(of: table, query: query)
        }
        return DataStoreFetchResult(descriptor: request.descriptor, fetchedSnapshots: snapshots)
    }

    public func fetchCount<T: PersistentModel>(_ request: DataStoreFetchRequest<T>) throws -> Int {
        let table = try layout(Schema.entityName(for: T.self))
        var descriptor = request.descriptor
        descriptor.sortBy = []
        return try lock.withLock {
            let query = try plan(descriptor, table: table, fallback: false)
            let sql = "SELECT count(*) FROM (SELECT 1 " + query + ")"
            let count = try db.scalar(sql.text, sql.bindings) as? Int64
            return Int(count ?? 0)
        }
    }

    public func fetchIdentifiers<T: PersistentModel>(_ request: DataStoreFetchRequest<T>) throws -> [PersistentIdentifier] {
        let table = try layout(Schema.entityName(for: T.self))
        return try lock.withLock {
            let query = try plan(request.descriptor, table: table, fallback: false)
            return try db.prepare("SELECT t0.\(q(EntityTable.primaryKey)) " + query.text, query.bindings).map { row in
                try codec.identifier(entity: table.name, primaryKey: row[0] as! String)
            }
        }
    }

    /// `FROM … WHERE … ORDER BY … LIMIT …` for a descriptor, root table aliased `t0`.
    ///
    /// When part of it has no SQL equivalent and `fallback` is true, throws
    /// `preferInMemoryFilter`/`preferInMemorySort` so SwiftData evaluates that part.
    /// SwiftData does not apply `fetchLimit`/`fetchOffset` after such a fallback, and
    /// cannot fall back for counts or identifiers, so those cases throw `unsupportedQuery`.
    private func plan<T>(_ descriptor: FetchDescriptor<T>, table: EntityTable, fallback: Bool) throws -> SQL {
        do {
            let (from, whereSQL, order) = try SQLQueryBuilder(tables: tables).clauses(for: descriptor, entity: table.name)
            var sql = "FROM " + from + whereSQL + order
            if let limit = descriptor.fetchLimit { sql = sql + " LIMIT \(limit)" }
            if let offset = descriptor.fetchOffset { sql = sql + (descriptor.fetchLimit == nil ? " LIMIT -1" : "") + " OFFSET \(offset)" }
            return sql
        } catch let error as Untranslatable {
            guard fallback, descriptor.fetchLimit == nil, (descriptor.fetchOffset ?? 0) == 0 else {
                throw CipherError.unsupportedQuery("""
                    \(error.reason) cannot run in SQL, and SwiftData cannot evaluate it in memory for this fetch \
                    (fetchLimit, fetchOffset, fetchCount or fetchIdentifiers). Simplify the predicate or sort, or drop the limit.
                    """)
            }
            var unsorted = descriptor
            unsorted.sortBy = []
            if descriptor.predicate != nil, (try? SQLQueryBuilder(tables: tables).clauses(for: unsorted, entity: table.name)) == nil {
                throw DataStoreError.preferInMemoryFilter
            }
            throw DataStoreError.preferInMemorySort
        }
    }

    private func readRows(of table: EntityTable, query: SQL) throws -> [DefaultSnapshot] {
        let toOne = table.toOne.keys.sorted()
        let columns = [EntityTable.primaryKey] + table.attributes.map(\.name) + toOne
        let statement = try db.prepare(
            "SELECT " + columns.map { "t0." + q($0) }.joined(separator: ", ") + " " + query.text, query.bindings
        )

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

    // MARK: - Import

    /// Writes rows copied from another store in one transaction and records `marker`.
    /// Returns `false` without writing when `marker` is already recorded. Rolls back unless
    /// every entity ends up with exactly its imported rows added.
    func importRows(_ rows: [(entity: String, key: String, object: [String: Any])], marker: String) throws -> Bool {
        try lock.withLock {
            if try db.scalar("SELECT 1 FROM _meta WHERE key = ?", marker) != nil { return false }
            try db.transaction(.immediate) {
                var expected: [String: Int] = [:]
                for table in tables.values {
                    expected[table.name] = Int(try db.scalar("SELECT count(*) FROM \(q(table.name))") as? Int64 ?? 0)
                }
                for row in rows {
                    try write(row.object, key: row.key, to: layout(row.entity), keyMap: [:])
                    expected[row.entity, default: 0] += 1
                }
                for (entity, count) in expected {
                    let actual = Int(try db.scalar("SELECT count(*) FROM \(q(entity))") as? Int64 ?? 0)
                    guard actual == count else {
                        throw CipherError.migrationFailed("\(entity) has \(actual) rows after import, expected \(count)")
                    }
                }
                try db.run("INSERT INTO _meta (key, value) VALUES (?, ?)", marker, ISO8601DateFormatter().string(from: Date()))
            }
            return true
        }
    }

    // MARK: - Maintenance

    /// Re-encrypts the store with `newKey`. Later opens must use `newKey`.
    /// A `.keychain` key that does not exist yet is created.
    public func rekey(to newKey: EncryptionKey) throws {
        let key = try newKey.resolved(createIfMissing: true)
        try lock.withLock {
            do {
                try key.rekey(db)
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
