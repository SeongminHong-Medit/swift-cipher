import Foundation
import SQLiteDB

public enum CipherBackup {
    /// Copies an encrypted store to `destinationURL`, encrypted with `destinationKey`.
    /// An existing file at `destinationURL` is replaced. Close containers on the source first.
    public static func export(
        from sourceURL: URL,
        sourceKey: EncryptionKey,
        to destinationURL: URL,
        destinationKey: EncryptionKey
    ) throws {
        try export(from: sourceURL, sourceKey: sourceKey, to: destinationURL, keyClause: destinationKey.resolved(createIfMissing: true).attachClause)
    }

    /// Copies an encrypted store to `destinationURL` **without encryption**, for example
    /// for debugging. Anyone with the file can read it.
    public static func exportPlaintext(
        from sourceURL: URL,
        sourceKey: EncryptionKey,
        to destinationURL: URL
    ) throws {
        // An empty key makes SQLCipher write a plain SQLite file.
        try export(from: sourceURL, sourceKey: sourceKey, to: destinationURL, keyClause: "KEY ''")
    }

    private static func export(from sourceURL: URL, sourceKey: EncryptionKey, to destinationURL: URL, keyClause: String) throws {
        let source = try sourceKey.resolved()
        let connection = try Connection(.uri(sourceURL.path))
        try CipherStore.unlock(connection, with: source)

        // Export next to the destination and swap it in only on success, so a failed
        // export never destroys an earlier backup.
        let temporary = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try connection.execute("ATTACH DATABASE \(sqlLiteral(temporary.path)) AS backup \(keyClause)")
            try connection.execute("SELECT sqlcipher_export('backup')")
            try connection.execute("DETACH DATABASE backup")
        } catch {
            throw CipherError.encryptionFailed("SQLCipher export failed: \(error)")
        }
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destinationURL)
        }
    }
}
