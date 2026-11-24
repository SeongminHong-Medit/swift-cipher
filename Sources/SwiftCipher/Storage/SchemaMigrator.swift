import Foundation
import SwiftData
import SQLiteDB

/// Brings an existing store's tables up to a schema before `CipherStore` opens it.
///
/// The store records its layout signature in `_meta`. When it differs from the schema's,
/// the file is copied aside, the migration plan's stages run from the version the store is
/// at, and remaining differences are applied as a lightweight migration. Any failure puts
/// the copy back, so the store is never left half-migrated.
enum SchemaMigrator {
    static let backupSuffix = ".migration-backup"

    static func tables(of schema: Schema) throws -> [String: EntityTable] {
        var tables: [String: EntityTable] = [:]
        for entity in schema.entities {
            tables[entity.name] = try EntityTable(entity, in: schema)
        }
        return tables
    }

    static func signature(of tables: [String: EntityTable]) -> String {
        tables.keys.sorted().map { tables[$0]!.signature }.joined(separator: ";")
    }

    static func recordSignature(_ signature: String, in db: Connection) throws {
        try db.run("INSERT OR REPLACE INTO _meta (key, value) VALUES ('layout', ?)", signature)
    }

    static func migrate(
        url: URL,
        key: ResolvedKey,
        schema: Schema,
        configuration: CipherConfiguration,
        plan: (any SchemaMigrationPlan.Type)?
    ) throws {
        let target = signature(of: try tables(of: schema))
        let stored: String?
        do {
            let db = try open(url, key)
            stored = try? db.scalar("SELECT value FROM _meta WHERE key = 'layout'") as? String
            let userTables = try db.scalar(
                "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name <> '_meta' AND name NOT LIKE 'sqlite_%'"
            ) as? Int64 ?? 0
            if stored == target || userTables == 0 { return }
            try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        }

        let backup = URL(fileURLWithPath: url.path + backupSuffix)
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.copyItem(at: url, to: backup)
        do {
            if let plan, let stored {
                try runStages(of: plan, from: stored, url: url, key: key, configuration: configuration)
            }
            try evolve(url: url, key: key, to: schema)
        } catch {
            try restore(url, from: backup)
            if let error = error as? CipherError { throw error }
            throw CipherError.migrationFailed("\(error)")
        }
        try? FileManager.default.removeItem(at: backup)
    }

    private static func open(_ url: URL, _ key: ResolvedKey) throws -> Connection {
        let db = try Connection(.uri(url.path))
        try CipherStore.unlock(db, with: key)
        db.busyTimeout = 5
        return db
    }

    private static func restore(_ url: URL, from backup: URL) throws {
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: backup)
    }

    // MARK: Plan

    private static func runStages(
        of plan: any SchemaMigrationPlan.Type,
        from stored: String,
        url: URL,
        key: ResolvedKey,
        configuration: CipherConfiguration
    ) throws {
        let schemas = plan.schemas
        guard var index = try schemas.firstIndex(where: { signature(of: try tables(of: Schema(versionedSchema: $0))) == stored }) else {
            return  // The store matches no version in the plan; only lightweight changes apply.
        }
        while let stage = plan.stages.first(where: { versions(of: $0).from.versionIdentifier == schemas[index].versionIdentifier }) {
            let to = versions(of: stage).to
            switch stage {
            case .lightweight:
                try evolve(url: url, key: key, to: Schema(versionedSchema: to))
            case let .custom(from, to, willMigrate, didMigrate):
                if let willMigrate { try run(willMigrate, schema: Schema(versionedSchema: from), configuration: configuration) }
                try evolve(url: url, key: key, to: Schema(versionedSchema: to))
                if let didMigrate { try run(didMigrate, schema: Schema(versionedSchema: to), configuration: configuration) }
            @unknown default:
                throw CipherError.migrationFailed("unknown migration stage \(stage)")
            }
            guard let next = schemas.firstIndex(where: { $0.versionIdentifier == to.versionIdentifier }), next != index else { break }
            index = next
        }
    }

    private static func versions(of stage: MigrationStage) -> (from: any VersionedSchema.Type, to: any VersionedSchema.Type) {
        switch stage {
        case let .lightweight(from, to): (from, to)
        case let .custom(from, to, _, _): (from, to)
        @unknown default: fatalError("unknown migration stage \(stage)")
        }
    }

    /// Runs a stage closure on a container opened with that stage's schema. The store is
    /// already at that schema, so the nested open does not migrate.
    private static func run(
        _ body: (ModelContext) throws -> Void,
        schema: Schema,
        configuration: CipherConfiguration
    ) throws {
        var configuration = configuration
        configuration.schema = schema
        configuration.migrationPlan = nil
        let context = ModelContext(try ModelContainer(for: schema, configurations: [configuration]))
        try body(context)
        if context.hasChanges { try context.save() }
    }

    // MARK: Lightweight

    private static func evolve(url: URL, key: ResolvedKey, to schema: Schema) throws {
        let tables = try tables(of: schema)
        let db = try open(url, key)
        try db.transaction(.immediate) {
            try db.execute("CREATE TABLE IF NOT EXISTS _meta (key TEXT PRIMARY KEY NOT NULL, value TEXT)")
            for name in tables.keys.sorted() {
                try evolve(tables[name]!, in: db)
            }
            try recordSignature(signature(of: tables), in: db)
        }
    }

    private static func evolve(_ table: EntityTable, in db: Connection) throws {
        var existing: [String: String] = [:]
        for row in try db.prepare("PRAGMA table_info(\(q(table.name)))") {
            existing[row[1] as! String] = (row[2] as? String)?.uppercased() ?? ""
        }
        if existing.isEmpty {
            for sql in table.createStatements { try db.execute(sql) }
            return
        }

        for attribute in table.attributes {
            let property = "\(table.name).\(attribute.name)"
            if let type = existing[attribute.name] {
                guard type == attribute.kind.sqlType else {
                    throw CipherError.migrationFailed("""
                        \(property) changed type. Add a new property instead and copy the values in a custom MigrationStage.
                        """)
                }
                continue
            }
            if let original = attribute.originalName, existing[original] == attribute.kind.sqlType {
                try db.execute("ALTER TABLE \(q(table.name)) RENAME COLUMN \(q(original)) TO \(q(attribute.name))")
                continue
            }
            try db.execute("ALTER TABLE \(q(table.name)) ADD COLUMN \(q(attribute.name)) \(attribute.kind.sqlType)")
            if !attribute.isOptional {
                guard let value = try defaultBinding(attribute) else {
                    throw CipherError.migrationFailed("""
                        \(property) was added without a default value, so existing rows cannot be filled. \
                        Give it one (`var \(attribute.name): … = …`), make it optional, or fill it in a custom MigrationStage.
                        """)
                }
                try db.run("UPDATE \(q(table.name)) SET \(q(attribute.name)) = ?", value)
            }
        }
        for name in table.toOne.keys.sorted() where existing[name] == nil {
            try db.execute("ALTER TABLE \(q(table.name)) ADD COLUMN \(q(name)) TEXT")
        }

        // Rebuild this table's indexes so they follow the schema's unique constraints and #Index.
        let indexes = try db.prepare(
            "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ? AND substr(name, 1, 4) IN ('_uq_', '_ix_', '_fk_')",
            table.name
        ).map { $0[0] as! String }
        for index in indexes { try db.execute("DROP INDEX \(q(index))") }
        do {
            for sql in table.createStatements { try db.execute(sql) }
        } catch {
            throw CipherError.migrationFailed("""
                could not apply \(table.name)'s unique constraints or indexes (\(error)). \
                Remove duplicates in a custom MigrationStage's willMigrate.
                """)
        }
    }

    private static func defaultBinding(_ attribute: AttributeColumn) throws -> Binding?? {
        guard let value = flattenOptional(attribute.defaultValue), let encodable = value as? any Encodable else { return nil }
        let data = try JSONEncoder().encode(encodable)
        let object = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        return .some(try RowCodec(storeIdentifier: "").binding(for: object, kind: attribute.kind))
    }
}
