import SwiftUI
import SwiftData

/// Holds the container across view updates so the store is opened once, not on every `body`.
private final class ContainerBox {
    var result: Result<ModelContainer, Error>?
}

private struct CipherContainerModifier<Failure: View>: ViewModifier {
    let configuration: CipherConfiguration
    let failure: (Error) -> Failure
    @State private var box = ContainerBox()

    func body(content: Content) -> some View {
        let result = box.result ?? Result {
            try CipherContainer.makeContainer(for: configuration.schema ?? Schema(), configurations: [configuration])
        }
        box.result = result
        return Group {
            switch result {
            case .success(let container): content.modelContainer(container)
            case .failure(let error): failure(error)
            }
        }
    }
}

extension View {
    /// Sets an encrypted model container for this view, like `modelContainer(for:)`.
    ///
    /// - Parameter failure: Shown instead of the view when the store cannot be opened,
    ///   for example when the Keychain is still locked (`CipherError.keychainError(errSecInteractionNotAllowed)`).
    public func cipherContainer<Failure: View>(
        for schema: Schema,
        encryptionKey: EncryptionKey? = nil,
        name: String = "default",
        storeURL: URL? = nil,
        appGroup: String? = nil,
        @ViewBuilder failure: @escaping (Error) -> Failure
    ) -> some View {
        let configuration = CipherConfiguration(
            name: name, schema: schema, encryptionKey: encryptionKey, storeURL: storeURL, appGroup: appGroup
        )
        return modifier(CipherContainerModifier(configuration: configuration, failure: failure))
    }

    /// Sets an encrypted model container for this view, like `modelContainer(for:)`.
    /// If the store cannot be opened, a message is shown instead of the view.
    public func cipherContainer(
        for schema: Schema,
        encryptionKey: EncryptionKey? = nil,
        name: String = "default",
        storeURL: URL? = nil,
        appGroup: String? = nil
    ) -> some View {
        cipherContainer(for: schema, encryptionKey: encryptionKey, name: name, storeURL: storeURL, appGroup: appGroup) { error in
            ContentUnavailableView("Data Unavailable", systemImage: "lock", description: Text(error.localizedDescription))
        }
    }
}
