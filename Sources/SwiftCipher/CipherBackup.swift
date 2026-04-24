import Foundation
import SQLiteDB

// MARK: - Data Helper

private extension Data {
    func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - CipherBackup

public enum CipherBackup {
    /// Exports an encrypted SQLite database to `destinationURL`.
    ///
    /// - Parameters:
    ///   - sourceURL: Path to the source encrypted database.
    ///   - sourceKey: Encryption key used to open the source.
    ///   - destinationURL: Path for the exported copy (will be overwritten if it exists).
    ///   - destinationKey: Key for the exported copy; `nil` exports as plaintext.
    public static func export(
        from sourceURL: URL,
        sourceKey: EncryptionKey,
        to destinationURL: URL,
        destinationKey: EncryptionKey? = nil
    ) throws {
        // Validate keys before touching any files.
        try sourceKey.validate()
        try destinationKey?.validate()

        let destPath = destinationURL.path

        // Track whether we created/modified the destination so we can clean up on error.
        var destinationCreated = false

        defer {
            if destinationCreated && FileManager.default.fileExists(atPath: destPath) {
                // Only clean up if we're unwinding due to an error; this defer runs
                // after the do/catch below sets `destinationCreated` back to false on success.
                try? FileManager.default.removeItem(at: destinationURL)
            }
        }

        do {
            try withExtendedLifetime(()) { _ in
                // Open the source database.
                let connection = try Connection(.uri(sourceURL.path))

                // Apply the source key.
                do {
                    switch sourceKey {
                    case .passphrase(let s):
                        try connection.key(s)
                    case .raw(let data):
                        try connection.key(Blob(bytes: Array(data)))
                    }
                } catch {
                    throw CipherError.encryptionFailed("invalid source key")
                }

                // Verify the source key is correct.
                do {
                    _ = try connection.scalar("SELECT count(*) FROM sqlite_master;")
                } catch {
                    throw CipherError.encryptionFailed("invalid source key")
                }

                // Remove existing destination file so ATTACH can create a fresh one.
                if FileManager.default.fileExists(atPath: destPath) {
                    try FileManager.default.removeItem(at: destinationURL)
                }

                // Mark that we are about to create the destination file.
                destinationCreated = true

                // Build the ATTACH SQL with the appropriate destination key.
                let attachSQL: String
                if let destKey = destinationKey {
                    switch destKey {
                    case .passphrase(let s):
                        let escaped = s.replacingOccurrences(of: "'", with: "''")
                        attachSQL = "ATTACH DATABASE '\(destPath)' AS backup KEY '\(escaped)'"
                    case .raw(let data):
                        attachSQL = "ATTACH DATABASE '\(destPath)' AS backup KEY \"x'\(data.hexEncodedString())'\""
                    }
                } else {
                    // Empty key string = plaintext export in SQLCipher.
                    attachSQL = "ATTACH DATABASE '\(destPath)' AS backup KEY ''"
                }

                try connection.execute(attachSQL)
                try connection.execute("SELECT sqlcipher_export('backup')")
                try connection.execute("DETACH DATABASE backup")
            }

            // Export succeeded — do not clean up the destination.
            destinationCreated = false
        } catch let cipherErr as CipherError {
            throw cipherErr
        } catch {
            throw CipherError.encryptionFailed("SQLCipher export failed: \(error)")
        }
    }
}
