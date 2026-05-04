import Foundation
import SwiftData
import SQLiteDB

// MARK: - Data Helper

private extension Data {
    func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - CipherMigration

public enum CipherMigration {
    /// Migrates data from a plaintext SwiftData `DefaultStore` into a fresh `CipherStore`.
    ///
    /// Opens the existing store at `sourceURL` using SwiftData's default `ModelConfiguration`,
    /// creates a new encrypted `CipherStore` at `destinationURL`, then calls `migration` with
    /// both contexts. The caller is responsible for copying entities; the function handles
    /// store lifecycle and cleanup on failure.
    ///
    /// - Parameters:
    ///   - sourceURL: Path to the existing (unencrypted) DefaultStore database.
    ///   - sourceSchema: The SwiftData `Schema` describing the stored models.
    ///   - destinationURL: Path where the new encrypted store will be created.
    ///   - encryptionKey: Encryption key for the new `CipherStore`.
    ///   - migration: Closure that receives `(source: ModelContext, destination: ModelContext)`.
    ///     Insert entities into `destination`; the function saves when the closure returns.
    public static func migrateData(
        from sourceURL: URL,
        sourceSchema: Schema,
        to destinationURL: URL,
        encryptionKey: EncryptionKey,
        using migration: (_ source: ModelContext, _ destination: ModelContext) throws -> Void
    ) throws {
        try encryptionKey.validate()
        try? FileManager.default.removeItem(at: destinationURL)

        var destinationCreated = false
        defer {
            if destinationCreated {
                try? FileManager.default.removeItem(at: destinationURL)
            }
        }

        let sourceConfig = ModelConfiguration(url: sourceURL)
        let sourceContainer = try ModelContainer(for: sourceSchema, configurations: sourceConfig)
        let sourceContext = ModelContext(sourceContainer)

        let destContainer = try CipherContainer.makeContainer(
            for: sourceSchema,
            encryptionKey: encryptionKey,
            storeURL: destinationURL
        )
        let destContext = ModelContext(destContainer)
        destinationCreated = true

        try migration(sourceContext, destContext)
        try destContext.save()

        destinationCreated = false
    }

    /// Encrypts an existing plaintext SQLite database in-place.
    /// The original file at `url` is replaced with an encrypted version.
    /// A temporary file is used during conversion; cleaned up on success or failure.
    public static func encrypt(
        fileAt url: URL,
        using encryptionKey: EncryptionKey
    ) throws {
        try encryptionKey.validate()

        let tempPath = url.path + ".cipher_tmp"
        let tempURL = URL(fileURLWithPath: tempPath)

        // Ensure any leftover temp file from a prior failed run is removed first.
        try? FileManager.default.removeItem(at: tempURL)

        // Defer cleanup of the temp file on any exit path.
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        do {
            // Use a local scope so `db` is released (and the connection closed)
            // before we attempt to replace the file.
            try withExtendedLifetime(()) { _ in
                let db = try Connection(.uri(url.path))

                let attachSQL: String
                switch encryptionKey {
                case .passphrase(let s):
                    let escaped = s.replacingOccurrences(of: "'", with: "''")
                    attachSQL = "ATTACH DATABASE '\(tempPath)' AS encrypted KEY '\(escaped)'"
                case .raw(let data):
                    attachSQL = "ATTACH DATABASE '\(tempPath)' AS encrypted KEY \"x'\(data.hexEncodedString())'\""
                }

                try db.execute(attachSQL)
                try db.execute("SELECT sqlcipher_export('encrypted')")
                try db.execute("DETACH DATABASE encrypted")
                // `db` goes out of scope here, closing the connection.
            }
        } catch {
            throw CipherError.migrationFailed("SQLCipher export failed: \(error)")
        }

        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } catch {
            throw CipherError.migrationFailed("File replacement failed: \(error)")
        }
    }
}
