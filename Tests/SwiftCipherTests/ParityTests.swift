import Testing
import SwiftData
import Foundation
@testable import SwiftCipher

/// Behavior every app relies on. Each test runs on the default SwiftData store and the
/// cipher store; both must give the same answer.
@Suite("Parity: basic persistence")
struct BasicParityTests {

    @Test("all attribute types survive save and reopen", arguments: StoreKind.allCases)
    func attributeRoundTrip(kind: StoreKind) throws {
        let store = try TempStore(kind, [Item.self])
        defer { store.destroy() }

        let original = Item(
            title: "milk", count: 3, score: 4.5, isDone: true,
            createdAt: Date(timeIntervalSinceReferenceDate: 12345.678),
            note: "2%", rating: 5, priority: .high,
            stops: [Address(city: "Busan", zip: 1)], labels: ["x": 1]
        )
        let uid = original.uid
        do {
            let context = ModelContext(try store.container())
            context.insert(original)
            context.insert(Item(title: "empty"))
            try context.save()
        }

        let context = ModelContext(try store.container())
        let items = try context.fetch(FetchDescriptor<Item>()).sorted { $0.title < $1.title }
        try #require(items.count == 2)
        let empty = items[0], milk = items[1]

        #expect(milk.title == "milk")
        #expect(milk.count == 3)
        #expect(milk.score == 4.5)
        #expect(milk.isDone == true)
        #expect(milk.createdAt == Date(timeIntervalSinceReferenceDate: 12345.678))
        #expect(milk.payload == Data("milk".utf8))
        #expect(milk.uid == uid)
        #expect(milk.link == URL(string: "https://example.com/milk"))
        #expect(milk.note == "2%")
        #expect(milk.rating == 5)
        #expect(milk.priority == .high)
        #expect(milk.level == .two)
        #expect(milk.address == Address(city: "Seoul", zip: 3))
        #expect(milk.stops == [Address(city: "Busan", zip: 1)])
        #expect(milk.labels == ["x": 1])

        #expect(empty.note == nil)
        #expect(empty.rating == nil)
        #expect(empty.stops == [])
    }

    @Test("update and delete persist across reopen", arguments: StoreKind.allCases)
    func updateAndDelete(kind: StoreKind) throws {
        let store = try TempStore(kind, [Item.self])
        defer { store.destroy() }

        do {
            let context = ModelContext(try store.container())
            context.insert(Item(title: "keep"))
            context.insert(Item(title: "drop"))
            try context.save()

            let all = try context.fetch(FetchDescriptor<Item>())
            for item in all {
                if item.title == "keep" { item.count = 42; item.note = "edited" }
                else { context.delete(item) }
            }
            try context.save()
        }

        let context = ModelContext(try store.container())
        let items = try context.fetch(FetchDescriptor<Item>())
        #expect(items.map(\.title) == ["keep"])
        #expect(items.first?.count == 42)
        #expect(items.first?.note == "edited")
    }

    @Test("fetchCount matches inserted rows", arguments: StoreKind.allCases)
    func count(kind: StoreKind) throws {
        let store = try TempStore(kind, [Item.self])
        defer { store.destroy() }
        let context = ModelContext(try store.container())
        for i in 0..<5 { context.insert(Item(title: "i\(i)")) }
        try context.save()
        #expect(try ModelContext(store.container()).fetchCount(FetchDescriptor<Item>()) == 5)
    }
}
