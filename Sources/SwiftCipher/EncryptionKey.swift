import Foundation

public enum CipherError: Error, Sendable, Equatable {
    case invalidKeyLength
    case encryptionFailed(String)
    case migrationFailed(String)
    case keychainError(OSStatus)
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
