import Testing
import SwiftData
import Foundation
@testable import SwiftCipher

// Successive versions of one app's model. Each version's `Note` is the same entity.

enum NotesV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [Note.self] }
    @Model final class Note {
        var title: String
        var stars: Int
        init(title: String, stars: Int = 0) { self.title = title; self.stars = stars }
    }
}

/// Lightweight changes: rename, new property with a default, new optional, new entity.
enum NotesV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] { [Note.self, Folder.self] }
    @Model final class Note {
        @Attribute(originalName: "title") var name: String
        var stars: Int
        var body: String = ""
        var pinnedAt: Date?
        init(name: String) { self.name = name; self.stars = 0 }
    }
    @Model final class Folder {
        var label: String
        init(label: String) { self.label = label }
    }
}

/// Plan versions. Apple's staged migration rejects new non-optional properties even
/// with defaults, so the plan only renames and adds optionals, keeping it a parity test.
enum PlanV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] { [Note.self] }
    @Model final class Note {
        @Attribute(originalName: "title") var name: String
        var stars: Int
        var pinnedAt: Date?
        init(name: String) { self.name = name; self.stars = 0 }
    }
}

/// Needs a custom stage: `name` becomes unique, so duplicates must go first.
enum PlanV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)
    static var models: [any PersistentModel.Type] { [Note.self] }
    @Model final class Note {
        @Attribute(.unique, originalName: "title") var name: String
        var stars: Int
        var pinnedAt: Date?
        init(name: String) { self.name = name; self.stars = 0 }
    }
}

/// A new Codable enum with a default. Apple's store crashes reading it after a lightweight
/// migration (the value is never filled in); the cipher store fills the default.
enum NotesEnumV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 1, 0)
    static var models: [any PersistentModel.Type] { [Note.self] }
    @Model final class Note {
        var title: String
        var stars: Int
        var priority: Priority = Priority.high
        init(title: String) { self.title = title; self.stars = 0 }
    }
}

/// Adds a non-optional property with no default: no lightweight migration can fill it.
enum NotesBadV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 1)
    static var models: [any PersistentModel.Type] { [Note.self] }
    @Model final class Note {
        var title: String
        var stars: Int
        var required: String
        init(title: String) { self.title = title; self.stars = 0; self.required = "" }
    }
}

enum NotesPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [NotesV1.self, PlanV2.self, PlanV3.self] }
    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: NotesV1.self, toVersion: PlanV2.self),
            .custom(fromVersion: PlanV2.self, toVersion: PlanV3.self, willMigrate: { context in
                var seen = Set<String>()
                for note in try context.fetch(FetchDescriptor<PlanV2.Note>(sortBy: [SortDescriptor(\.stars, order: .reverse)])) {
                    if !seen.insert(note.name).inserted { context.delete(note) }
                }
                try context.save()
            }, didMigrate: { context in
                for note in try context.fetch(FetchDescriptor<PlanV3.Note>()) { note.pinnedAt = .distantPast }
                try context.save()
            }),
        ]
    }
}

@Suite("Schema migration", .serialized)
struct MigrationTests {

    func container(_ store: TempStore, _ version: any VersionedSchema.Type, plan: (any SchemaMigrationPlan.Type)? = nil) throws -> ModelContainer {
        let schema = Schema(versionedSchema: version)
        switch store.kind {
        case .swiftData:
            return try ModelContainer(for: schema, migrationPlan: plan, configurations: [ModelConfiguration(schema: schema, url: store.url)])
        case .cipher:
            let configuration = CipherConfiguration(schema: schema, encryptionKey: .passphrase("test"), storeURL: store.url, migrationPlan: plan)
            return try ModelContainer(for: schema, configurations: [configuration])
        }
    }

    func seedV1(_ store: TempStore, _ rows: [(String, Int)]) throws {
        let context = ModelContext(try container(store, NotesV1.self))
        for (title, stars) in rows { context.insert(NotesV1.Note(title: title, stars: stars)) }
        try context.save()
    }

    @Test("lightweight changes apply on open without a plan", arguments: StoreKind.allCases)
    func lightweight(kind: StoreKind) throws {
        let store = try TempStore(kind, [])
        defer { store.destroy() }
        try seedV1(store, [("a", 1), ("b", 2)])

        let context = ModelContext(try container(store, NotesV2.self))
        let notes = try context.fetch(FetchDescriptor<NotesV2.Note>(sortBy: [SortDescriptor(\.name)]))
        #expect(notes.map(\.name) == ["a", "b"])
        #expect(notes.map(\.stars) == [1, 2])
        #expect(notes.allSatisfy { $0.body == "" && $0.pinnedAt == nil })
        context.insert(NotesV2.Folder(label: "inbox"))
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<NotesV2.Folder>()) == 1)
    }

    @Test("a plan's custom stage runs willMigrate and didMigrate around the schema change", arguments: StoreKind.allCases)
    func customStage(kind: StoreKind) throws {
        let store = try TempStore(kind, [])
        defer { store.destroy() }
        try seedV1(store, [("dup", 1), ("dup", 5), ("solo", 2)])

        let context = ModelContext(try container(store, PlanV3.self, plan: NotesPlan.self))
        let notes = try context.fetch(FetchDescriptor<PlanV3.Note>(sortBy: [SortDescriptor(\.name)]))
        #expect(notes.map(\.name) == ["dup", "solo"])
        #expect(notes.map(\.stars) == [5, 2])
        #expect(notes.allSatisfy { $0.pinnedAt == .distantPast })
    }

    @Test("an impossible migration fails with a clear error and leaves the store as it was")
    func failureRestoresStore() throws {
        let store = try TempStore(.cipher, [])
        defer { store.destroy() }
        try seedV1(store, [("a", 1)])
        let before = try Data(contentsOf: store.url)

        do {
            _ = try container(store, NotesBadV2.self)
            Issue.record("expected migrationFailed")
        } catch let CipherError.migrationFailed(message) {
            #expect(message.contains("Note.required"))
        }
        #expect(try Data(contentsOf: store.url) == before)
        let context = ModelContext(try container(store, NotesV1.self))
        #expect(try context.fetch(FetchDescriptor<NotesV1.Note>()).map(\.title) == ["a"])
    }

    @Test("a new Codable enum property gets its default value")
    func enumDefault() throws {
        let store = try TempStore(.cipher, [])
        defer { store.destroy() }
        try seedV1(store, [("a", 1)])
        let context = ModelContext(try container(store, NotesEnumV2.self))
        #expect(try context.fetch(FetchDescriptor<NotesEnumV2.Note>()).map(\.priority) == [.high])
    }

    @Test("opening an up-to-date store does not touch the file")
    func noOp() throws {
        let store = try TempStore(.cipher, [])
        defer { store.destroy() }
        try seedV1(store, [("a", 1)])
        _ = try container(store, NotesV1.self)
        let backup = store.directory.appendingPathComponent("store.sqlite.migration-backup")
        #expect(!FileManager.default.fileExists(atPath: backup.path))
    }
}
