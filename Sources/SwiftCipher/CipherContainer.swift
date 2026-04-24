import SwiftData
import Foundation

public enum CipherContainer {
    public static func makeContainer(
        for schema: Schema,
        encryptionKey: EncryptionKey,
        name: String = "default",
        storeURL: URL? = nil,
        migrationPlan: (any SchemaMigrationPlan.Type)? = nil
    ) throws -> ModelContainer {
        let configuration = CipherConfiguration(
            name: name,
            schema: schema,
            encryptionKey: encryptionKey,
            storeURL: storeURL
        )
        try configuration.validate()
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    public static func makeContainer(
        for schema: Schema,
        configurations: [CipherConfiguration],
        migrationPlan: (any SchemaMigrationPlan.Type)? = nil
    ) throws -> ModelContainer {
        for configuration in configurations {
            try configuration.validate()
        }
        return try ModelContainer(for: schema, configurations: configurations)
    }
}
