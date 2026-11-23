import Foundation
import SwiftData
import SQLiteDB

/// Converts between `DefaultSnapshot` and SQLite column values.
///
/// `DefaultSnapshot` exposes its contents only through `Codable`, so values travel through
/// its JSON form: a flat object keyed by property name, relationships encoded as
/// `PersistentIdentifier` objects.
// shortcut: one JSON round trip per row; replace with a dedicated Encoder/Decoder if profiling shows it.
struct RowCodec {
    let storeIdentifier: String

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: Snapshot → row

    func object(from snapshot: DefaultSnapshot) throws -> [String: Any] {
        let data = try encoder.encode(snapshot)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CipherError.storeCorrupted("snapshot did not encode as an object")
        }
        return object
    }

    func binding(for value: Any?, kind: ColumnKind) throws -> Binding? {
        guard let value, !(value is NSNull) else { return nil }
        switch kind {
        case .json:
            let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
            return String(decoding: data, as: UTF8.self)
        case .blob:
            guard let base64 = value as? String, let data = Data(base64Encoded: base64) else {
                throw CipherError.storeCorrupted("expected base64 data, got \(type(of: value))")
            }
            return Blob(bytes: Array(data))
        case .bool:
            guard let bool = value as? Bool else { throw mismatch(value, kind) }
            return Int64(bool ? 1 : 0)
        case .integer:
            guard let number = value as? NSNumber else { throw mismatch(value, kind) }
            return number.int64Value
        case .real:
            guard let number = value as? NSNumber else { throw mismatch(value, kind) }
            return number.doubleValue
        case .text:
            guard let string = value as? String else { throw mismatch(value, kind) }
            return string
        }
    }

    /// The primary key stored for an encoded `PersistentIdentifier` (permanent or temporary).
    func primaryKey(ofEncodedIdentifier value: Any?) -> String? {
        guard let object = value as? [String: Any],
              let implementation = object["implementation"] as? [String: Any] else { return nil }
        return implementation["primaryKey"] as? String
    }

    // MARK: Row → snapshot

    func value(from binding: Binding?, kind: ColumnKind) throws -> Any {
        guard let binding else { return NSNull() }
        switch (kind, binding) {
        case (.json, let text as String):
            return try JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)
        case (.blob, let blob as Blob):
            return Data(blob.bytes).base64EncodedString()
        case (.bool, let int as Int64):
            return int != 0
        case (.integer, let int as Int64):
            return int
        case (.real, let double as Double):
            return double
        case (.real, let int as Int64):
            return Double(int)
        case (.text, let string as String):
            return string
        default:
            throw CipherError.storeCorrupted("column of kind \(kind) holds \(type(of: binding))")
        }
    }

    func identifier(entity: String, primaryKey: String) throws -> PersistentIdentifier {
        try PersistentIdentifier.identifier(for: storeIdentifier, entityName: entity, primaryKey: primaryKey)
    }

    func encodedIdentifier(entity: String, primaryKey: String) throws -> Any {
        let data = try encoder.encode(identifier(entity: entity, primaryKey: primaryKey))
        return try JSONSerialization.jsonObject(with: data)
    }

    func snapshot(from object: [String: Any]) throws -> DefaultSnapshot {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try decoder.decode(DefaultSnapshot.self, from: data)
    }

    private func mismatch(_ value: Any, _ kind: ColumnKind) -> CipherError {
        CipherError.storeCorrupted("value \(type(of: value)) does not fit a \(kind) column")
    }
}
