# swift-cipher

A SwiftData store that encrypts your database on disk with [SQLCipher](https://www.zetetic.net/sqlcipher/).
Keep your `@Model` types, `@Query`, and `ModelContext` code: change one line where the container is created.

```swift
let container = try ModelContainer(for: Schema([Note.self]), configurations: [CipherConfiguration()])
```

## Requirements

| Platform  | Minimum version |
|-----------|-----------------|
| iOS       | 18.0            |
| macOS     | 15.0            |
| tvOS      | 18.0            |
| watchOS   | 11.0            |
| visionOS  | 2.0             |

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/KKodiac/swift-cipher.git", from: "1.0.0")
],
targets: [
    .target(name: "MyTarget", dependencies: ["SwiftCipher"])
]
```

## Usage

### Create the container

```swift
import SwiftData
import SwiftCipher

@main
struct NotesApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .cipherContainer(for: Schema([Note.self]))
        }
    }
}
```

Or create the container yourself, which lets you handle errors at launch:

```swift
let schema = Schema([Note.self])
let container = try ModelContainer(for: schema, configurations: [CipherConfiguration(schema: schema)])
```

The store is written to `default.store` in Application Support. Pass `name:` or `storeURL:` to `CipherConfiguration` to choose another file.

`.cipherContainer` shows a message in place of the view if the store cannot be opened. Pass `failure:` to show your own view:

```swift
ContentView()
    .cipherContainer(for: Schema([Note.self])) { error in
        MyErrorView(error: error)
    }
```

### Encryption keys

By default, the package creates a random 32-byte key the first time a store is opened and keeps it in the Keychain under the store's name. Your code contains no secret.

The Keychain item:
- is readable after the device is first unlocked, so background launches work;
- moves to a new device with an encrypted backup or Quick Start, as the store file does.

Other options:

```swift
CipherConfiguration(encryptionKey: .keychain(account: "notes", accessGroup: "TEAMID.com.example.shared"))
CipherConfiguration(encryptionKey: .passphrase(passphraseTheUserTyped))  // SQLCipher derives the key with PBKDF2
CipherConfiguration(encryptionKey: .raw(thirtyTwoBytes))                  // your own key management
```

If the Keychain has no key but the store file exists, opening it throws `CipherError.keyNotFound` and leaves the file alone. A new key could never open it.

### Sharing the store with app extensions

Set an App Group and a Keychain access group that both the app and the extension have:

```swift
CipherConfiguration(
    encryptionKey: .keychain(account: "notes", accessGroup: "TEAMID.com.example.shared"),
    appGroup: "group.com.example.shared"
)
```

### Moving an existing SwiftData store into an encrypted one

```swift
let types: [any PersistentModel.Type] = [Note.self, Folder.self]
let legacyURL = URL.applicationSupportDirectory.appending(path: "default.store")
let configuration = CipherConfiguration(schema: Schema(types))

if FileManager.default.fileExists(atPath: legacyURL.path) {
    try CipherMigration.importSwiftDataStore(at: legacyURL, types: types, into: configuration)
    try CipherMigration.removeSwiftDataStore(at: legacyURL)
}
let container = try ModelContainer(for: Schema(types), configurations: [configuration])
```

How the import behaves:
- It opens the old store read-only.
- It copies every model and relationship in one transaction and checks the row counts before committing.
- It records that the import happened. If the app quits before `removeSwiftDataStore` runs, the next call does nothing.

### Changing your models

Lightweight changes apply automatically when the store opens:
- new models and properties;
- renames with `@Attribute(originalName:)`;
- new non-optional properties with a default value;
- changes to `@Attribute(.unique)` and `#Index`.

For anything else, pass a `SchemaMigrationPlan` on the configuration. `ModelContainer` does not pass a migration plan to custom stores:

```swift
CipherConfiguration(schema: Schema(versionedSchema: NotesV3.self), migrationPlan: NotesPlan.self)
```

`willMigrate` and `didMigrate` of custom stages run as they do with the default store.

Before migrating, the store copies its file. If any step fails, it puts the copy back and throws `CipherError.migrationFailed`, with a message naming the property and what to change.

### Changing the key

```swift
try CipherContainer.rekey(storeAt: url, from: .passphrase("old"), to: .passphrase("new"))
```

Close every container that uses the store first.

### Backups

```swift
try CipherBackup.export(from: storeURL, sourceKey: key, to: backupURL, destinationKey: .passphrase("backup"))
try CipherBackup.exportPlaintext(from: storeURL, sourceKey: key, to: debugURL)  // unencrypted: debugging only
```

A failed export leaves any earlier backup at the destination unchanged.

## Errors

| `CipherError` | Meaning |
|---|---|
| `wrongKey` | The key does not open the file, or the file is not an encrypted database. |
| `keyNotFound(account:)` | The store exists, but its Keychain key is gone. |
| `keychainError(errSecInteractionNotAllowed)` | The device has not been unlocked since it started. Try again after unlock. |
| `unsupportedSchema` | A model uses something listed under [Limitations](#limitations). The message names it. |
| `unsupportedQuery` | A query cannot run in SQL, and SwiftData cannot run it in memory either. See below. |
| `migrationFailed` | A schema change could not be applied. The store is unchanged. |

## How queries run

Predicates, sorts, `fetchLimit`/`fetchOffset`, `fetchCount` and `fetchIdentifiers` run in SQL. Supported predicates:
- comparisons, `&&`, `||` and `!`;
- optionals: `== nil`, `??` and optional chaining;
- `[values].contains(x)`;
- string `contains`, `localizedStandardContains` and `starts(with:)`;
- key paths through to-one relationships;
- `contains(where:)` on to-many relationships;
- `persistentModelID`.

Sorts work on attributes and through to-one relationships. String operations and sorts use the same Swift methods as in-memory evaluation, so results match the default store.

Anything else, such as a predicate on a property of a Codable struct, is handed to SwiftData to evaluate in memory. SwiftData cannot do that for `fetchLimit`, `fetchOffset`, `fetchCount` or `fetchIdentifiers`, so those combinations throw `unsupportedQuery` rather than return wrong results.

## Limitations

- **Arrays and sets of plain values** (`[String]`, `Set<Int>`) are stored by SwiftData as transformable attributes. SwiftData cannot read those back from custom stores, so opening the store throws `unsupportedSchema`. Wrap the value in a Codable struct:
  ```swift
  struct Tags: Codable { var values: [String] }
  ```
  Arrays of Codable structs and dictionaries work as they are.
- **Model inheritance** is not supported yet.
- **CloudKit sync** and **history tracking** (`fetchHistory`) are not available for custom stores.
- **App Store export compliance**: the app uses encryption beyond Apple's operating system. Answer the export compliance questions in App Store Connect accordingly. Encrypting the user's own data on the device usually qualifies for an exemption.

## License

MIT
