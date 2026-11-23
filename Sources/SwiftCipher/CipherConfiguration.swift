import SwiftData
import Foundation

public struct CipherConfiguration: DataStoreConfiguration {
    public typealias Store = CipherStore

    public var name: String
    public var schema: Schema?
    public var encryptionKey: EncryptionKey
    public var storeURL: URL?

    public init(
        name: String = "default",
        schema: Schema? = nil,
        encryptionKey: EncryptionKey,
        storeURL: URL? = nil
    ) {
        self.name = name
        self.schema = schema
        self.encryptionKey = encryptionKey
        self.storeURL = storeURL
    }

    /// `storeURL`, or `<name>.sqlite` in Application Support.
    func resolvedStoreURL() throws -> URL {
        if let storeURL { return storeURL }
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return directory.appendingPathComponent("\(name).sqlite")
    }

    public func validate() throws {
        try encryptionKey.validate()
    }

    public static func == (lhs: CipherConfiguration, rhs: CipherConfiguration) -> Bool {
        lhs.name == rhs.name && lhs.storeURL == rhs.storeURL
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(storeURL)
    }
}
