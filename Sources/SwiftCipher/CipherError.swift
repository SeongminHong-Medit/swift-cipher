import Foundation

public enum CipherError: Error, Sendable, Equatable {
    /// A raw key is not exactly 32 bytes.
    case invalidKeyLength
    /// The key does not decrypt the store, or the file is not an encrypted database.
    /// SQLCipher cannot tell these apart.
    case wrongKey
    /// `EncryptionKey.keychain` found no key, but a store file already exists. A new key
    /// would not open it, so none is created. Typical causes: the app was restored to a new
    /// device without its Keychain, or the key was deleted.
    case keyNotFound(account: String)
    /// A Keychain call failed. `errSecInteractionNotAllowed` means the device has not been
    /// unlocked since it started, which happens when the app launches in the background.
    case keychainError(OSStatus)
    /// Re-keying or exporting the database failed.
    case encryptionFailed(String)
    case migrationFailed(String)
    /// The schema uses a feature the cipher store cannot persist. The message names the model and property.
    case unsupportedSchema(String)
    /// The fetch needs a predicate or sort the store cannot run in SQL, combined with
    /// `fetchLimit`/`fetchOffset`, `fetchCount` or `fetchIdentifiers`, where SwiftData
    /// cannot evaluate it in memory instead. The message names the unsupported part.
    case unsupportedQuery(String)
    /// The store file holds data the store cannot interpret.
    case storeCorrupted(String)
}

extension CipherError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidKeyLength: "Raw encryption keys must be exactly 32 bytes."
        case .wrongKey: "The encryption key does not open this store, or the file is not an encrypted database."
        case .keyNotFound(let account): "No encryption key named \"\(account)\" is in the Keychain, but an encrypted store already exists."
        case .keychainError(let status):
            status == errSecInteractionNotAllowed
                ? "The Keychain is locked until the device is unlocked for the first time after starting."
                : "Keychain error \(status)."
        case .encryptionFailed(let message): "Encryption failed: \(message)"
        case .migrationFailed(let message): "Migration failed: \(message)"
        case .unsupportedSchema(let message): message
        case .unsupportedQuery(let message): message
        case .storeCorrupted(let message): "The store is damaged: \(message)"
        }
    }
}
