import Foundation

public enum CipherError: Error, Sendable, Equatable {
    case invalidKeyLength
    case encryptionFailed(String)
    case migrationFailed(String)
    case keychainError(OSStatus)
    /// The schema uses a feature the cipher store cannot persist. The message names the model and property.
    case unsupportedSchema(String)
    /// The store file holds data the store cannot interpret.
    case storeCorrupted(String)
    /// The fetch needs a predicate or sort the store cannot run in SQL, combined with
    /// `fetchLimit`/`fetchOffset`, `fetchCount` or `fetchIdentifiers`, where SwiftData
    /// cannot evaluate it in memory instead. The message names the unsupported part.
    case unsupportedQuery(String)
}

public enum EncryptionKey: Sendable {
    case passphrase(String)
    case raw(Data)

    public func validate() throws {
        if case .raw(let data) = self, data.count != 32 {
            throw CipherError.invalidKeyLength
        }
    }
}
