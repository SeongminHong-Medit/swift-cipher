import Foundation
import SwiftData

/// How an attribute value is stored in its SQLite column.
enum ColumnKind: Equatable {
    case integer
    case real
    case text
    case bool
    /// `Data`: base64 in the snapshot, raw bytes in SQLite.
    case blob
    /// Enums, Codable structs, collections: JSON text, opaque to SQL.
    case json

    var sqlType: String {
        switch self {
        case .integer, .bool: "INTEGER"
        case .real: "REAL"
        case .text, .json: "TEXT"
        case .blob: "BLOB"
        }
    }

    init(for valueType: Any.Type) {
        let type = unwrapOptional(valueType)
        switch type {
        case is Bool.Type: self = .bool
        case is Data.Type: self = .blob
        case is Int.Type, is Int8.Type, is Int16.Type, is Int32.Type, is Int64.Type,
             is UInt.Type, is UInt8.Type, is UInt16.Type, is UInt32.Type, is UInt64.Type:
            self = .integer
        case is Double.Type, is Float.Type, is Date.Type: self = .real
        case is String.Type, is UUID.Type, is URL.Type: self = .text
        default: self = .json
        }
    }
}

/// Strips any number of `Optional` wrappers from a metatype.
func unwrapOptional(_ type: Any.Type) -> Any.Type {
    (type as? any OptionalProtocol.Type)?.wrappedType.map(unwrapOptional) ?? type
}

protocol OptionalProtocol { static var wrappedType: Any.Type? { get } }
extension Optional: OptionalProtocol { static var wrappedType: Any.Type? { Wrapped.self } }

struct AttributeColumn {
    let name: String
    let kind: ColumnKind
}

/// A to-many relationship the store must persist itself. To-many relationships whose
/// inverse is to-one are not stored: they are read back from the inverse's column.
struct JoinTable {
    let relationship: String
    let destination: String
    let table: String
}

/// The SQLite layout for one entity.
struct EntityTable {
    static let primaryKey = "_pk"

    let name: String
    let attributes: [AttributeColumn]
    /// Relationship name → destination entity. Column holds the destination's primary key.
    let toOne: [String: String]
    /// Relationship name → (destination entity, inverse to-one column on the destination).
    let derivedToMany: [String: (destination: String, inverse: String)]
    let joinTables: [JoinTable]
    let uniqueConstraints: [[String]]
    let indices: [[String]]

    init(_ entity: Schema.Entity, in schema: Schema) throws {
        if let attribute = entity.attributes.first(where: \.isTransformable) {
            throw CipherError.unsupportedSchema("""
                \(entity.name).\(attribute.name) (\(attribute.valueType)) is a transformable attribute. \
                SwiftData cannot read transformable values back from custom stores. \
                Wrap the value in a Codable struct, for example `struct Tags: Codable { var values: [String] }`.
                """)
        }
        if !entity.subentities.isEmpty || entity.superentity != nil {
            throw CipherError.unsupportedSchema("\(entity.name) uses model inheritance, which the cipher store does not support yet.")
        }

        name = entity.name
        attributes = entity.attributes
            .sorted { $0.name < $1.name }
            .map { AttributeColumn(name: $0.name, kind: ColumnKind(for: $0.valueType)) }

        var toOne: [String: String] = [:]
        var derived: [String: (String, String)] = [:]
        var joins: [JoinTable] = []
        for relationship in entity.relationships.sorted(by: { $0.name < $1.name }) {
            if relationship.isToOneRelationship {
                toOne[relationship.name] = relationship.destination
            } else if let inverse = relationship.inverseName,
                      schema.entitiesByName[relationship.destination]?
                        .relationshipsByName[inverse]?.isToOneRelationship == true {
                derived[relationship.name] = (relationship.destination, inverse)
            } else {
                joins.append(JoinTable(
                    relationship: relationship.name,
                    destination: relationship.destination,
                    table: "_join_\(entity.name)_\(relationship.name)"
                ))
            }
        }
        self.toOne = toOne
        self.derivedToMany = derived
        self.joinTables = joins
        uniqueConstraints = entity.uniquenessConstraints
        indices = entity.indices
    }

    var createStatements: [String] {
        let pk = Self.primaryKey
        var columns = ["\(q(pk)) TEXT PRIMARY KEY NOT NULL"]
        columns += attributes.map { "\(q($0.name)) \($0.kind.sqlType)" }
        columns += toOne.keys.sorted().map { "\(q($0)) TEXT" }
        var sql = ["CREATE TABLE IF NOT EXISTS \(q(name)) (\(columns.joined(separator: ", ")))"]
        for (i, constraint) in uniqueConstraints.enumerated() {
            sql.append("CREATE UNIQUE INDEX IF NOT EXISTS \(q("_uq_\(name)_\(i)")) ON \(q(name)) (\(constraint.map(q).joined(separator: ", ")))")
        }
        for (i, index) in indices.enumerated() {
            sql.append("CREATE INDEX IF NOT EXISTS \(q("_ix_\(name)_\(i)")) ON \(q(name)) (\(index.map(q).joined(separator: ", ")))")
        }
        for column in toOne.keys.sorted() {
            sql.append("CREATE INDEX IF NOT EXISTS \(q("_fk_\(name)_\(column)")) ON \(q(name)) (\(q(column)))")
        }
        for join in joinTables {
            sql.append("CREATE TABLE IF NOT EXISTS \(q(join.table)) (owner TEXT NOT NULL, target TEXT NOT NULL, PRIMARY KEY (owner, target))")
            sql.append("CREATE INDEX IF NOT EXISTS \(q("_ix_\(join.table)_target")) ON \(q(join.table)) (target)")
        }
        return sql
    }
}

/// Quotes an SQL identifier.
func q(_ identifier: String) -> String {
    "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}
