import Foundation
import SQLiteDB

public enum EncryptionKey: Sendable, Hashable {
    /// A random 32-byte key created on first use and kept in the Keychain. Recommended:
    /// no secret appears in your code, and nothing is derived from a user's password.
    ///
    /// The item is readable after the device's first unlock, so background launches work,
    /// and moves to a new device with an encrypted backup or Quick Start, like the store file.
    ///
    /// - Parameters:
    ///   - account: Names the key. Use one per store.
    ///   - accessGroup: A Keychain access group shared with your app extensions, if they open the store.
    case keychain(account: String = "default", accessGroup: String? = nil)
    /// A passphrase. SQLCipher derives the key from it with PBKDF2.
    case passphrase(String)
    /// A 32-byte key used as is.
    case raw(Data)

    public func validate() throws {
        if case .raw(let data) = self, data.count != 32 {
            throw CipherError.invalidKeyLength
        }
    }

    /// The passphrase or raw key to give SQLCipher. For `.keychain`, reads the key, or
    /// creates one when `createIfMissing` and no store exists yet.
    func resolved(createIfMissing: Bool = false) throws -> ResolvedKey {
        try validate()
        switch self {
        case .passphrase(let passphrase): return .passphrase(passphrase)
        case .raw(let data): return .raw(data)
        case let .keychain(account, accessGroup):
            if let key = try CipherKeychain.key(account: account, accessGroup: accessGroup) { return .raw(key) }
            guard createIfMissing else { throw CipherError.keyNotFound(account: account) }
            return .raw(try CipherKeychain.createKey(account: account, accessGroup: accessGroup))
        }
    }
}

/// A key ready for SQLCipher.
enum ResolvedKey {
    case passphrase(String)
    case raw(Data)

    func unlock(_ connection: Connection) throws {
        switch self {
        case .passphrase(let s): try connection.key(s)
        case .raw(let data): try connection.key(Blob(bytes: Array(data)))
        }
    }

    func rekey(_ connection: Connection) throws {
        switch self {
        case .passphrase(let s): try connection.rekey(s)
        case .raw(let data): try connection.rekey(Blob(bytes: Array(data)))
        }
    }

    /// The `KEY …` clause for `ATTACH DATABASE`.
    var attachClause: String {
        switch self {
        case .passphrase(let s): "KEY '\(s.replacingOccurrences(of: "'", with: "''"))'"
        case .raw(let data): "KEY \"x'\(data.map { String(format: "%02x", $0) }.joined())'\""
        }
    }
}

/// Quotes a string as an SQL literal.
func sqlLiteral(_ string: String) -> String {
    "'" + string.replacingOccurrences(of: "'", with: "''") + "'"
}
