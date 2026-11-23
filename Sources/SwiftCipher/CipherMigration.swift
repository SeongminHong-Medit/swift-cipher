import Foundation
import SQLiteDB

// MARK: - CipherMigration

public enum CipherMigration {
    /// Encrypts an existing plaintext SQLite database in-place.
    /// The original file at `url` is replaced with an encrypted version.
    /// A temporary file is used during conversion; cleaned up on success or failure.
    public static func encrypt(
        fileAt url: URL,
        using encryptionKey: EncryptionKey
    ) throws {
        let key = try encryptionKey.resolved(createIfMissing: true)

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

                let attachSQL = "ATTACH DATABASE \(sqlLiteral(tempPath)) AS encrypted \(key.attachClause)"
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
