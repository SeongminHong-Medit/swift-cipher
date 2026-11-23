import Testing
import SwiftData
import Foundation
import SQLiteDB
@testable import SwiftCipher

@Suite("Parity: relationships, uniqueness, concurrency")
struct RelationshipParityTests {

    static let types: [any PersistentModel.Type] = [Author.self, Book.self, Genre.self]

    @Test("to-one and to-many saved in the same batch survive reopen", arguments: StoreKind.allCases)
    func oneToMany(kind: StoreKind) throws {
        let store = try TempStore(kind, Self.types)
        defer { store.destroy() }
        do {
            let context = ModelContext(try store.container())
            let author = Author(handle: "ann")
            context.insert(author)
            for title in ["a", "b"] {
                let book = Book(title: title)
                context.insert(book)
                book.author = author
            }
            context.insert(Book(title: "orphan"))
            try context.save()
        }

        let context = ModelContext(try store.container())
        let author = try #require(try context.fetch(FetchDescriptor<Author>()).first)
        #expect(author.books.map(\.title).sorted() == ["a", "b"])
        let books = try context.fetch(FetchDescriptor<Book>())
        #expect(books.first { $0.title == "a" }?.author?.handle == "ann")
        #expect(books.first { $0.title == "orphan" }?.author == nil)
    }

    @Test("many-to-many survives reopen from both sides", arguments: StoreKind.allCases)
    func manyToMany(kind: StoreKind) throws {
        let store = try TempStore(kind, Self.types)
        defer { store.destroy() }
        do {
            let context = ModelContext(try store.container())
            let fiction = Genre(name: "fiction"), poetry = Genre(name: "poetry")
            let book = Book(title: "verse")
            [fiction, poetry].forEach(context.insert)
            context.insert(book)
            book.genres = [fiction, poetry]
            try context.save()
        }

        let context = ModelContext(try store.container())
        let book = try #require(try context.fetch(FetchDescriptor<Book>()).first)
        #expect(book.genres.map(\.name).sorted() == ["fiction", "poetry"])
        let genres = try context.fetch(FetchDescriptor<Genre>())
        #expect(genres.allSatisfy { $0.books.map(\.title) == ["verse"] })
    }

    @Test("cascade delete removes children; nullify leaves no dangling reference", arguments: StoreKind.allCases)
    func deleteRules(kind: StoreKind) throws {
        let store = try TempStore(kind, Self.types)
        defer { store.destroy() }
        do {
            let context = ModelContext(try store.container())
            let author = Author(handle: "ann")
            let book = Book(title: "a")
            let genre = Genre(name: "g")
            context.insert(author); context.insert(book); context.insert(genre)
            book.author = author
            book.genres = [genre]
            try context.save()
            context.delete(author)
            try context.save()
        }

        let context = ModelContext(try store.container())
        #expect(try context.fetchCount(FetchDescriptor<Author>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Book>()) == 0)
        let genre = try #require(try context.fetch(FetchDescriptor<Genre>()).first)
        #expect(genre.books.isEmpty)
    }

    @Test("inserting a duplicate unique value updates the existing row", arguments: StoreKind.allCases)
    func uniqueUpsert(kind: StoreKind) throws {
        let store = try TempStore(kind, Self.types)
        defer { store.destroy() }
        do {
            let context = ModelContext(try store.container())
            context.insert(Author(handle: "ann", name: "first"))
            try context.save()
        }
        do {
            let context = ModelContext(try store.container())
            context.insert(Author(handle: "ann", name: "second"))
            try context.save()
        }

        let context = ModelContext(try store.container())
        let authors = try context.fetch(FetchDescriptor<Author>())
        #expect(authors.map(\.name) == ["second"])
    }

    @Test("concurrent saves from background contexts all land", arguments: StoreKind.allCases)
    func concurrentSaves(kind: StoreKind) async throws {
        let store = try TempStore(kind, [Item.self])
        defer { store.destroy() }
        let container = try store.container()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    let context = ModelContext(container)
                    for i in 0..<25 { context.insert(Item(title: "w\(worker)-\(i)")) }
                    try context.save()
                }
            }
            try await group.waitForAll()
        }
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Item>()) == 200)
    }
}

@Suite("Cipher store layout")
struct CipherLayoutTests {

    @Test("each attribute has its own column, and nothing is readable without the key")
    func realColumns() throws {
        let store = try TempStore(.cipher, [Item.self])
        defer { store.destroy() }
        let context = ModelContext(try store.container())
        context.insert(Item(title: "secret-title", count: 7))
        try context.save()

        let db = try Connection(.uri(store.url.path))
        try db.key("test")
        let columns = try db.prepare("PRAGMA table_info(\"Item\")").map { $0[1] as! String }
        #expect(Set(columns).isSuperset(of: ["_pk", "title", "count", "score", "createdAt", "address"]))
        #expect(try db.scalar("SELECT \"count\" FROM \"Item\"") as? Int64 == 7)

        let raw = try Data(contentsOf: store.url)
        #expect(raw.range(of: Data("secret-title".utf8)) == nil)
    }

    @Test("a transformable attribute is rejected when the container opens, naming the property")
    func transformableRejected() throws {
        let store = try TempStore(.cipher, [Tagged.self])
        defer { store.destroy() }
        do {
            _ = try store.container()
            Issue.record("expected unsupportedSchema")
        } catch let CipherError.unsupportedSchema(message) {
            #expect(message.contains("Tagged.tags"))
        }
    }
}
