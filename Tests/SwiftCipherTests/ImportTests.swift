import Testing
import SwiftData
import Foundation
@testable import SwiftCipher

@Suite("Import from a SwiftData store")
struct ImportTests {

    static let types: [any PersistentModel.Type] = [Item.self, Author.self, Book.self, Genre.self]

    /// A default SwiftData store with attributes and every relationship kind.
    static func legacyStore(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("legacy.store")
        let schema = Schema(types)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
        let context = ModelContext(container)
        context.insert(Item(title: "milk", count: 2, note: "2%", stops: [Address(city: "Busan", zip: 1)]))
        let ann = Author(handle: "ann")
        let genre = Genre(name: "poetry")
        context.insert(ann); context.insert(genre)
        for title in ["a1", "a2"] {
            let book = Book(title: title, pages: 10)
            context.insert(book)
            book.author = ann
            book.genres = [genre]
        }
        try context.save()
        return url
    }

    @Test("copies every model and relationship, leaves the source untouched, and is safe to repeat")
    func importStore() throws {
        let store = try TempStore(.cipher, Self.types)
        defer { store.destroy() }
        let legacy = try Self.legacyStore(in: store.directory)
        let sourceBefore = try Data(contentsOf: legacy)
        let configuration = CipherConfiguration(schema: store.schema, encryptionKey: .passphrase("test"), storeURL: store.url)

        #expect(try CipherMigration.importSwiftDataStore(at: legacy, types: Self.types, into: configuration))
        #expect(try CipherMigration.importSwiftDataStore(at: legacy, types: Self.types, into: configuration) == false)
        #expect(try Data(contentsOf: legacy) == sourceBefore)

        let context = ModelContext(try store.container())
        let item = try #require(try context.fetch(FetchDescriptor<Item>()).first)
        #expect(item.title == "milk" && item.count == 2 && item.note == "2%")
        #expect(item.stops == [Address(city: "Busan", zip: 1)])
        let author = try #require(try context.fetch(FetchDescriptor<Author>()).first)
        #expect(author.books.map(\.title).sorted() == ["a1", "a2"])
        let genre = try #require(try context.fetch(FetchDescriptor<Genre>()).first)
        #expect(genre.books.map(\.title).sorted() == ["a1", "a2"])
        #expect(try context.fetchCount(FetchDescriptor<Book>()) == 2)

        try CipherMigration.removeSwiftDataStore(at: legacy)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test("a failed import leaves the encrypted store empty")
    func failedImportRollsBack() throws {
        let store = try TempStore(.cipher, Self.types)
        defer { store.destroy() }
        let legacy = try Self.legacyStore(in: store.directory)
        let configuration = CipherConfiguration(schema: store.schema, encryptionKey: .passphrase("test"), storeURL: store.url)

        // A row that already uses the unique handle makes the import's insert fail midway.
        do {
            let context = ModelContext(try store.container())
            context.insert(Author(handle: "ann"))
            try context.save()
        }
        #expect(throws: CipherError.self) {
            try CipherMigration.importSwiftDataStore(at: legacy, types: Self.types, into: configuration)
        }
        let context = ModelContext(try store.container())
        #expect(try context.fetchCount(FetchDescriptor<Book>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Author>()) == 1)
    }
}
