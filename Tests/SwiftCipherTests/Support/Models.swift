import SwiftData
import Foundation

enum Priority: String, Codable, Sendable { case low, high }
enum Level: Int, Codable, Sendable { case one = 1, two = 2 }
struct Address: Codable, Hashable, Sendable { var city: String; var zip: Int }

/// Covers every attribute shape the cipher store supports: scalars, optionals, enums,
/// Codable structs, arrays of Codable structs and dictionaries.
@Model final class Item {
    var title: String
    var count: Int
    var score: Double
    var isDone: Bool
    var createdAt: Date
    var payload: Data
    var uid: UUID
    var link: URL?
    var note: String?
    var rating: Int?
    var priority: Priority
    var level: Level
    var address: Address
    var stops: [Address]
    var labels: [String: Int]

    init(
        title: String,
        count: Int = 0,
        score: Double = 0,
        isDone: Bool = false,
        createdAt: Date = Date(timeIntervalSinceReferenceDate: 0),
        note: String? = nil,
        rating: Int? = nil,
        priority: Priority = .low,
        stops: [Address] = [],
        labels: [String: Int] = [:]
    ) {
        self.title = title
        self.count = count
        self.score = score
        self.isDone = isDone
        self.createdAt = createdAt
        self.payload = Data(title.utf8)
        self.uid = UUID()
        self.link = URL(string: "https://example.com/\(title)")
        self.note = note
        self.rating = rating
        self.priority = priority
        self.level = .two
        self.address = Address(city: "Seoul", zip: count)
        self.stops = stops
        self.labels = labels
    }
}

@Model final class Author {
    @Attribute(.unique) var handle: String
    var name: String
    @Relationship(deleteRule: .cascade, inverse: \Book.author) var books: [Book] = []
    init(handle: String, name: String = "") {
        self.handle = handle
        self.name = name
    }
}

@Model final class Book {
    var title: String
    var pages: Int
    var author: Author?
    @Relationship(inverse: \Genre.books) var genres: [Genre] = []
    init(title: String, pages: Int = 0) {
        self.title = title
        self.pages = pages
    }
}

/// Many-to-many with `Book`.
@Model final class Genre {
    var name: String
    var books: [Book] = []
    init(name: String) { self.name = name }
}

/// `[String]` is stored by SwiftData as a transformable attribute, which SwiftData cannot
/// read back from custom stores. Used to check the cipher store rejects it up front.
@Model final class Tagged {
    var tags: [String] = []
    init() {}
}
