import Testing
import SwiftData
import Foundation
@testable import SwiftCipher

/// Which backing store a parity test runs against. Every parity test runs on both;
/// the default SwiftData store is the reference behavior the cipher store must match.
enum StoreKind: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case swiftData
    case cipher

    var testDescription: String { rawValue }
}

/// A store file in a fresh temp directory. `container()` can be called repeatedly
/// to reopen the same file, which is how tests check data survives a relaunch.
struct TempStore {
    let kind: StoreKind
    let schema: Schema
    let directory: URL
    var url: URL { directory.appendingPathComponent("store.sqlite") }

    init(_ kind: StoreKind, _ types: [any PersistentModel.Type]) throws {
        self.kind = kind
        self.schema = Schema(types)
        self.directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-cipher-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func container() throws -> ModelContainer {
        switch kind {
        case .swiftData:
            return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
        case .cipher:
            let config = CipherConfiguration(schema: schema, encryptionKey: .passphrase("test"), storeURL: url)
            return try ModelContainer(for: schema, configurations: [config])
        }
    }

    func destroy() {
        try? FileManager.default.removeItem(at: directory)
    }
}
