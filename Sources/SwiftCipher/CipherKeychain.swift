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
}
