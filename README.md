# swift-cipher

A SwiftData store backed by SQLCipher that transparently encrypts your database on disk.

## Requirements

| Platform  | Minimum version |
|-----------|-----------------|
| iOS       | 18.0            |
| macOS     | 15.0            |
| tvOS      | 18.0            |
| watchOS   | 11.0            |
| visionOS  | 2.0             |

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/KKodiac/swift-cipher.git", from: "1.0.0")
],
targets: [
    .target(
        name: "MyTarget",
        dependencies: ["SwiftCipher"]
    )
]
```

Then import the module where needed:

```swift
import SwiftCipher
```

## Usage

### Basic setup

Create a `ModelContainer` using `CipherContainer.makeContainer(for:encryptionKey:)`. Pass either a passphrase or a 32-byte raw key.

```swift
import SwiftData
import SwiftCipher

@Model final class Note {
    var title: String
    init(title: String) { self.title = title }
}

let schema = Schema([Note.self])

// Passphrase key
let container = try CipherContainer.makeContainer(
    for: schema,
    encryptionKey: .passphrase("correct-horse-battery-staple")
)

// 32-byte raw key
let keyData = Data(repeating: 0x42, count: 32)
let container = try CipherContainer.makeContainer(
    for: schema,
    encryptionKey: .raw(keyData)
)
```

The store file is written to the application support directory as `<name>.sqlite` (default name is `"default"`). Pass `storeURL:` to choose a different location:

```swift
let url = URL.documentsDirectory.appending(path: "notes.sqlite")
let container = try CipherContainer.makeContainer(
    for: schema,
    encryptionKey: .passphrase("my-passphrase"),
    storeURL: url
)
```

### SwiftUI integration

Use the `.cipherContainer(for:encryptionKey:)` view modifier instead of `.modelContainer`. If the container fails to open, an error message is shown in place of the view.

```swift
@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .cipherContainer(
                    for: Schema([Note.self]),
                    encryptionKey: .passphrase("my-passphrase")
                )
        }
    }
}
```

### Keychain-backed key storage

Use `CipherKeychain` to persist and retrieve a passphrase in the system Keychain so it does not appear in source code or user-visible storage.

```swift
// Store the passphrase once (e.g. at first launch or account creation)
try CipherKeychain.store(passphrase: "my-passphrase", for: "com.example.myapp.db")

// Retrieve it on subsequent launches
let passphrase = try CipherKeychain.retrieve(for: "com.example.myapp.db")
let container = try CipherContainer.makeContainer(
    for: Schema([Note.self]),
    encryptionKey: .passphrase(passphrase)
)

// Remove it when the user signs out
try CipherKeychain.delete(for: "com.example.myapp.db")
```

`CipherKeychain` stores items under the service identifier `"swift-cipher"`. The `identifier` parameter maps to `kSecAttrAccount` and must be unique per database.

### Migrating a plaintext database

If you have an existing unencrypted SQLite file, use `CipherMigration.encrypt(fileAt:using:)` to convert it in place before opening it with `CipherContainer`.

```swift
let existingDB = URL.documentsDirectory.appending(path: "legacy.sqlite")

try CipherMigration.encrypt(
    fileAt: existingDB,
    using: .passphrase("my-passphrase")
)

// The file at existingDB is now encrypted. Open it normally.
let container = try CipherContainer.makeContainer(
    for: Schema([Note.self]),
    encryptionKey: .passphrase("my-passphrase"),
    storeURL: existingDB
)
```

The migration writes to a temporary file alongside the source and replaces the original only after a successful export. If anything fails, the temporary file is removed and the original is untouched.

### Backup / export

`CipherBackup.export(from:sourceKey:to:destinationKey:)` copies an encrypted database to another location. The destination can be encrypted with a different key or exported as plaintext by omitting `destinationKey`.

```swift
let source = URL.documentsDirectory.appending(path: "notes.sqlite")
let backup = URL.documentsDirectory.appending(path: "notes.backup.sqlite")

// Export with the same key
try CipherBackup.export(
    from: source,
    sourceKey: .passphrase("my-passphrase"),
    to: backup,
    destinationKey: .passphrase("my-passphrase")
)

// Export as plaintext (e.g. for diagnostic purposes)
try CipherBackup.export(
    from: source,
    sourceKey: .passphrase("my-passphrase"),
    to: backup
)
```

### Re-keying (changing the passphrase)

Call `rekey(to:)` on a `CipherStore` instance to change the encryption key without closing the database. Instantiate the store directly from its configuration when you need to re-key.

```swift
let config = CipherConfiguration(
    name: "default",
    schema: Schema([Note.self]),
    encryptionKey: .passphrase("old-passphrase")
)

let store = try CipherStore(config, migrationPlan: nil)
try store.rekey(to: .passphrase("new-passphrase"))
```

After `rekey` returns, subsequent opens must use the new key.

### Multi-store

Pass an array of `CipherConfiguration` values to host multiple encrypted databases in a single `ModelContainer`.

```swift
let userConfig = CipherConfiguration(
    name: "user",
    schema: Schema([User.self]),
    encryptionKey: .passphrase("user-key")
)

let cacheConfig = CipherConfiguration(
    name: "cache",
    schema: Schema([CachedItem.self]),
    encryptionKey: .passphrase("cache-key")
)

let schema = Schema([User.self, CachedItem.self])
let container = try CipherContainer.makeContainer(
    for: schema,
    configurations: [userConfig, cacheConfig]
)
```

Each configuration writes to its own file (`user.sqlite` and `cache.sqlite` in the application support directory by default).

## License

MIT
