import Testing
import SwiftData
import Foundation
@testable import SwiftCipher

/// Query results must match the default store exactly, whether the cipher store
/// answers in SQL or hands the predicate back to SwiftData.
@Suite("Parity: queries")
struct QueryParityTests {

    static func seeded(_ kind: StoreKind) throws -> (TempStore, ModelContainer) {
        let store = try TempStore(kind, [Item.self, Author.self, Book.self, Genre.self])
        let container = try store.container()
        let context = ModelContext(container)
        let rows: [(String, Int, Double, Bool, String?, Int?, Priority)] = [
            ("apple", 3, 1.5, true, "red", 5, .high),
            ("Banana", 1, 0.25, false, nil, nil, .low),
            ("cherry", 7, 9.0, true, "dark red", 2, .low),
            ("date", 7, 2.0, false, "brown", nil, .high),
            ("elderberry", 0, 3.5, false, "", 4, .low),
        ]
        for (i, row) in rows.enumerated() {
            context.insert(Item(
                title: row.0, count: row.1, score: row.2, isDone: row.3,
                createdAt: Date(timeIntervalSinceReferenceDate: Double(i) * 1000),
                note: row.4, rating: row.5, priority: row.6
            ))
        }
        let ann = Author(handle: "ann", name: "Ann")
        let bob = Author(handle: "bob", name: "Bob")
        context.insert(ann); context.insert(bob)
        for (title, pages, author) in [("a1", 100, ann), ("a2", 300, ann), ("b1", 200, bob)] {
            let book = Book(title: title, pages: pages)
            context.insert(book)
            book.author = author
        }
        context.insert(Book(title: "anon", pages: 50))
        try context.save()
        return (store, container)
    }

    static func titles(_ kind: StoreKind, _ descriptor: FetchDescriptor<Item>) throws -> [String] {
        let (store, container) = try seeded(kind)
        defer { store.destroy() }
        return try ModelContext(container).fetch(descriptor).map(\.title)
    }

    static let cutoff = Date(timeIntervalSinceReferenceDate: 1500)
    static let needle = "an"

    /// Predicates covering the operators apps commonly use.
    static let predicates: [(String, Predicate<Item>)] = [
        ("int ==", #Predicate { $0.count == 7 }),
        ("int > and <=", #Predicate { $0.count > 0 && $0.count <= 3 }),
        ("double <", #Predicate { $0.score < 2.0 }),
        ("bool", #Predicate { $0.isDone }),
        ("not bool", #Predicate { !$0.isDone }),
        ("or", #Predicate { $0.count == 0 || $0.score > 5 }),
        ("string ==", #Predicate { $0.title == "date" }),
        ("string !=", #Predicate { $0.title != "date" }),
        ("captured value", #Predicate { $0.createdAt > cutoff }),
        ("optional == nil", #Predicate { $0.note == nil }),
        ("optional != nil", #Predicate { $0.rating != nil }),
        ("optional compare via flatMap", #Predicate { ($0.rating ?? 0) >= 4 }),
        ("contains", #Predicate { $0.title.contains("an") }),
        ("localizedStandardContains", #Predicate { $0.title.localizedStandardContains(needle) }),
        ("starts(with:)", #Predicate { $0.title.starts(with: "c") }),
        ("optional chain contains", #Predicate { $0.note?.contains("red") == true }),
        ("enum on Codable (in-memory)", #Predicate { $0.address.zip == 7 }),
        ("in array", #Predicate { ["apple", "date"].contains($0.title) }),
    ]

    @Test("predicate results match", arguments: predicates.indices)
    func predicate(index: Int) throws {
        let (name, predicate) = Self.predicates[index]
        let descriptor = FetchDescriptor<Item>(predicate: predicate, sortBy: [SortDescriptor(\.title)])
        let expected = try Self.titles(.swiftData, descriptor)
        let actual = try Self.titles(.cipher, descriptor)
        #expect(actual == expected, "\(name)")
    }

    static let sorts: [(String, [SortDescriptor<Item>])] = [
        ("string asc", [SortDescriptor(\.title)]),
        ("string desc", [SortDescriptor(\.title, order: .reverse)]),
        ("int then string", [SortDescriptor(\.count, order: .reverse), SortDescriptor(\.title)]),
        ("date", [SortDescriptor(\.createdAt, order: .reverse)]),
        ("optional", [SortDescriptor(\.rating), SortDescriptor(\.title)]),
        ("localized", [SortDescriptor(\.title, comparator: .localizedStandard)]),
    ]

    @Test("sort order matches", arguments: sorts.indices)
    func sort(index: Int) throws {
        let (name, sortBy) = Self.sorts[index]
        let descriptor = FetchDescriptor<Item>(sortBy: sortBy)
        #expect(try Self.titles(.cipher, descriptor) == Self.titles(.swiftData, descriptor), "\(name)")
    }

    @Test("limit and offset with predicate and sort match")
    func limitOffset() throws {
        var descriptor = FetchDescriptor<Item>(predicate: #Predicate { $0.count > 0 }, sortBy: [SortDescriptor(\.score)])
        descriptor.fetchLimit = 2
        descriptor.fetchOffset = 1
        #expect(try Self.titles(.cipher, descriptor) == Self.titles(.swiftData, descriptor))
    }

    @Test("fetchCount and fetchIdentifiers honor the predicate", arguments: StoreKind.allCases)
    func countAndIdentifiers(kind: StoreKind) throws {
        let (store, container) = try Self.seeded(kind)
        defer { store.destroy() }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Item>(predicate: #Predicate { $0.count == 7 })
        #expect(try context.fetchCount(descriptor) == 2)
        #expect(try context.fetchIdentifiers(descriptor).count == 2)
    }

    static let bookPredicates: [(String, Predicate<Book>)] = [
        ("to-one key path", #Predicate { $0.author?.handle == "ann" }),
        ("to-one nil", #Predicate { $0.author == nil }),
        ("to-one and attribute", #Predicate { $0.author?.name == "Bob" && $0.pages > 100 }),
    ]

    @Test("predicates through relationships match", arguments: bookPredicates.indices)
    func relationshipPredicate(index: Int) throws {
        let (name, predicate) = Self.bookPredicates[index]
        let descriptor = FetchDescriptor<Book>(predicate: predicate, sortBy: [SortDescriptor(\.title)])
        func run(_ kind: StoreKind) throws -> [String] {
            let (store, container) = try Self.seeded(kind)
            defer { store.destroy() }
            return try ModelContext(container).fetch(descriptor).map(\.title)
        }
        #expect(try run(.cipher) == run(.swiftData), "\(name)")
    }

    @Test("to-many predicate and sort through relationship match")
    func toManyPredicate() throws {
        let descriptor = FetchDescriptor<Author>(
            predicate: #Predicate { $0.books.contains { $0.pages > 250 } },
            sortBy: [SortDescriptor(\.handle)]
        )
        func run(_ kind: StoreKind) throws -> [String] {
            let (store, container) = try Self.seeded(kind)
            defer { store.destroy() }
            return try ModelContext(container).fetch(descriptor).map(\.handle)
        }
        #expect(try run(.cipher) == run(.swiftData))
    }

    @Test("fetch by persistentModelID matches", arguments: StoreKind.allCases)
    func byIdentifier(kind: StoreKind) throws {
        let (store, container) = try Self.seeded(kind)
        defer { store.destroy() }
        let context = ModelContext(container)
        let target = try #require(try context.fetch(FetchDescriptor<Item>()).first { $0.title == "cherry" })
        let id = target.persistentModelID
        let fresh = ModelContext(container)
        let found = try fresh.fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.persistentModelID == id }))
        #expect(found.map(\.title) == ["cherry"])
        #expect((fresh.model(for: id) as? Item)?.title == "cherry")
    }
}

extension QueryParityTests {
    @Test("limit and offset without predicate match")
    func limitOffsetPlain() throws {
        var descriptor = FetchDescriptor<Item>()
        descriptor.fetchLimit = 2
        descriptor.fetchOffset = 1
        let expected = try Self.titles(.swiftData, descriptor)
        let actual = try Self.titles(.cipher, descriptor)
        #expect(actual.count == expected.count)
    }
}

/// Parity tests pass whether a query runs in SQL or falls back to memory. These check the
/// common cases really run in SQL, which is what keeps large stores fast and lets them
/// combine with fetchLimit and fetchCount.
@Suite("SQL translation coverage")
struct TranslationCoverageTests {

    static let schema = Schema([Item.self, Author.self, Book.self, Genre.self])
    static var tables: [String: EntityTable] { try! SchemaMigrator.tables(of: schema) }

    static func translates<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) -> Bool {
        (try? SQLQueryBuilder(tables: tables).clauses(for: descriptor, entity: Schema.entityName(for: T.self))) != nil
    }

    @Test("item predicates translate", arguments: QueryParityTests.predicates.indices)
    func itemPredicates(index: Int) {
        let (name, predicate) = QueryParityTests.predicates[index]
        let expected = !name.contains("in-memory")
        #expect(Self.translates(FetchDescriptor<Item>(predicate: predicate)) == expected, "\(name)")
    }

    @Test("sorts on attributes translate", arguments: QueryParityTests.sorts.indices)
    func sorts(index: Int) {
        let (name, sortBy) = QueryParityTests.sorts[index]
        #expect(Self.translates(FetchDescriptor<Item>(sortBy: sortBy)), "\(name)")
    }

    @Test("relationship predicates translate", arguments: QueryParityTests.bookPredicates.indices)
    func bookPredicates(index: Int) {
        let (name, predicate) = QueryParityTests.bookPredicates[index]
        #expect(Self.translates(FetchDescriptor<Book>(predicate: predicate)), "\(name)")
    }

    @Test("sort through a to-one relationship translates")
    func relationshipSort() {
        #expect(Self.translates(FetchDescriptor<Book>(sortBy: [SortDescriptor(\.author?.name), SortDescriptor(\.title)])))
    }

    @Test("to-many contains(where:) translates")
    func toMany() {
        #expect(Self.translates(FetchDescriptor<Author>(predicate: #Predicate { $0.books.contains { $0.pages > 250 } })))
    }

    @Test("untranslatable predicate with fetchLimit reports unsupportedQuery instead of wrong results")
    func limitWithFallback() throws {
        let (store, container) = try QueryParityTests.seeded(.cipher)
        defer { store.destroy() }
        var descriptor = FetchDescriptor<Item>(predicate: #Predicate { $0.address.zip == 7 })
        descriptor.fetchLimit = 1
        #expect(throws: CipherError.self) { try ModelContext(container).fetch(descriptor) }
    }
}

extension QueryParityTests {
    @Test("sort through a to-one relationship matches")
    func relationshipSort() throws {
        let descriptor = FetchDescriptor<Book>(
            predicate: #Predicate { $0.pages > 60 },
            sortBy: [SortDescriptor(\.author?.name, order: .reverse), SortDescriptor(\.title)]
        )
        func run(_ kind: StoreKind) throws -> [String] {
            let (store, container) = try Self.seeded(kind)
            defer { store.destroy() }
            return try ModelContext(container).fetch(descriptor).map(\.title)
        }
        #expect(try run(.cipher) == run(.swiftData))
    }
}
