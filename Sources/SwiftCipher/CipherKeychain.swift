import Foundation
import Security

public enum CipherKeychain {

    private static let service = "swift-cipher"

    // MARK: - Public API

    public static func store(passphrase: String, for identifier: String) throws {
        guard let data = passphrase.data(using: .utf8) else {
            throw CipherError.keychainError(errSecParam)
        }

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: identifier
        ]

        let attributes: [CFString: Any] = [
            kSecValueData: data
        ]

        let status = SecItemAdd(query.merging([kSecValueData: data]) { _, new in new } as CFDictionary, nil)

        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw CipherError.keychainError(updateStatus)
            }
        } else if status != errSecSuccess {
            throw CipherError.keychainError(status)
        }
    }

    public static func retrieve(for identifier: String) throws -> String {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: identifier,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            throw CipherError.keychainError(status)
        }

        guard
            let data = result as? Data,
            let passphrase = String(data: data, encoding: .utf8)
        else {
            throw CipherError.keychainError(errSecDecode)
        }

        return passphrase
    }

    public static func delete(for identifier: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: identifier
        ]

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CipherError.keychainError(status)
        }
    }

    // MARK: - Store keys

    private static let keyService = "swift-cipher.key"

    private static func keyQuery(account: String, accessGroup: String?) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keyService,
            kSecAttrAccount: account,
        ]
        if let accessGroup { query[kSecAttrAccessGroup] = accessGroup }
        return query
    }

    /// The stored key, or `nil` when there is none. Any other failure throws, so a locked
    /// Keychain is never mistaken for a missing key.
    static func key(account: String, accessGroup: String?) throws -> Data? {
        var query = keyQuery(account: account, accessGroup: accessGroup)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CipherError.keychainError(status) }
        guard let data = result as? Data, data.count == 32 else { throw CipherError.keychainError(errSecDecode) }
        return data
    }

    static func createKey(account: String, accessGroup: String?) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let random = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard random == errSecSuccess else { throw CipherError.keychainError(random) }
        let key = Data(bytes)

        var item = keyQuery(account: account, accessGroup: accessGroup)
        item[kSecValueData] = key
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw CipherError.keychainError(status) }
        return key
    }

    /// Deletes a key created by `EncryptionKey.keychain`. Any store it encrypts can no longer be opened.
    public static func deleteKey(account: String = "default", accessGroup: String? = nil) throws {
        let status = SecItemDelete(keyQuery(account: account, accessGroup: accessGroup) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CipherError.keychainError(status)
        }
    }
}
