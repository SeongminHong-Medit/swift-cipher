import SwiftUI
import SwiftData

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private struct CipherContainerModifier: ViewModifier {
    let result: Result<ModelContainer, Error>

    func body(content: Content) -> some View {
        switch result {
        case .success(let container):
            content.modelContainer(container)
        case .failure(let error):
            content.overlay {
                Text(error.localizedDescription)
            }
        }
    }
}

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
extension View {
    public func cipherContainer(
        for models: [any PersistentModel.Type],
        encryptionKey: EncryptionKey,
        name: String = "default",
        storeURL: URL? = nil
    ) -> some View {
        cipherContainer(
            for: Schema(models),
            encryptionKey: encryptionKey,
            name: name,
            storeURL: storeURL
        )
    }

    public func cipherContainer(
        for schema: Schema,
        encryptionKey: EncryptionKey,
        name: String = "default",
        storeURL: URL? = nil
    ) -> some View {
        let result = Result<ModelContainer, Error> {
            try CipherContainer.makeContainer(
                for: schema,
                encryptionKey: encryptionKey,
                name: name,
                storeURL: storeURL
            )
        }
        return self.modifier(CipherContainerModifier(result: result))
    }
}
