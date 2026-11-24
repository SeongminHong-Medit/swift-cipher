import Testing
import SwiftData
import Foundation
@testable import SwiftCipher

@Suite("Keys and errors", .serialized)
struct KeyTests {

    @Test("default configuration creates a Keychain key and reopens with it")
    func keychainKeyRoundTrip() throws {
        let store = try TempStore(.cipher, [Item.self])
        let account = "test.\(UUID().uuidString)"
        defer { store.destroy(); try? CipherKeychain.deleteKey(account: account) }

        let configuration = CipherConfiguration(name: account, schema: store.schema, storeURL: store.url)
        #expect(configuration.encryptionKey == .keychain(account: account))
        do {
            let context = ModelContext(try ModelContainer(for: store.schema, configurations: [configuration]))
            context.insert(Item(title: "kept"))
            try context.save()
        }
        let context = ModelContext(try ModelContainer(for: store.schema, configurations: [configuration]))
        #expect(try context.fetch(FetchDescriptor<Item>()).map(\.title) == ["kept"])
    }

    @Test("a missing Keychain key for an existing store throws keyNotFound and leaves the file alone")
    func missingKeyIsNotRecreated() throws {
        let store = try TempStore(.cipher, [Item.self])
        let account = "test.\(UUID().uuidString)"
        defer { store.destroy(); try? CipherKeychain.deleteKey(account: account) }

        let configuration = CipherConfiguration(name: account, schema: store.schema, storeURL: store.url)
        do {
            let context = ModelContext(try ModelContainer(for: store.schema, configurations: [configuration]))
            context.insert(Item(title: "kept"))
            try context.save()
        }
        let before = try Data(contentsOf: store.url)
        try CipherKeychain.deleteKey(account: account)

        #expect(throws: CipherError.keyNotFound(account: account)) {
            _ = try CipherStore(configuration, migrationPlan: nil)
        }
        #expect(try Data(contentsOf: store.url) == before)
        #expect(try CipherKeychain.key(account: account, accessGroup: nil) == nil)
    }

    @Test("CipherContainer.rekey re-encrypts a closed store")
    func staticRekey() throws {
        let store = try TempStore(.cipher, [Item.self])
        defer { store.destroy() }
        do {
            let context = ModelContext(try store.container())
            context.insert(Item(title: "kept"))
            try context.save()
        }
        try CipherContainer.rekey(storeAt: store.url, from: .passphrase("test"), to: .passphrase("next"))

        let old = CipherConfiguration(schema: store.schema, encryptionKey: .passphrase("test"), storeURL: store.url)
        #expect(throws: CipherError.wrongKey) { _ = try CipherStore(old, migrationPlan: nil) }

        let new = CipherConfiguration(schema: store.schema, encryptionKey: .passphrase("next"), storeURL: store.url)
        let context = ModelContext(try ModelContainer(for: store.schema, configurations: [new]))
        #expect(try context.fetch(FetchDescriptor<Item>()).map(\.title) == ["kept"])
    }

    @Test("a failed export keeps the earlier backup")
    func failedExportKeepsBackup() throws {
        let store = try TempStore(.cipher, [Item.self])
        defer { store.destroy() }
        _ = try store.container()
        let backup = store.directory.appendingPathComponent("backup.sqlite")
        try Data("earlier backup".utf8).write(to: backup)

        #expect(throws: CipherError.wrongKey) {
            try CipherBackup.export(from: store.url, sourceKey: .passphrase("wrong"), to: backup, destinationKey: .passphrase("x"))
        }
        #expect(try Data(contentsOf: backup) == Data("earlier backup".utf8))
    }

    @Test("errors carry a readable description")
    func descriptions() {
        #expect(CipherError.wrongKey.localizedDescription.contains("does not open"))
        #expect(CipherError.keychainError(errSecInteractionNotAllowed).localizedDescription.contains("locked"))
    }
}

@Suite("README usage")
struct ReadmeUsageTests {
    @Test("a configuration without a schema takes the container's schema")
    func configurationWithoutSchema() throws {
        let store = try TempStore(.cipher, [Item.self])
        let name = "test.\(UUID().uuidString)"
        defer { store.destroy(); try? CipherKeychain.deleteKey(account: name) }
        let container = try ModelContainer(for: Schema([Item.self]), configurations: [CipherConfiguration(name: name, storeURL: store.url)])
        let context = ModelContext(container)
        context.insert(Item(title: "x"))
        try context.save()
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Item>()) == 1)
    }
}
