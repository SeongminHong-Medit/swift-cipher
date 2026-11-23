import SwiftUI
import SwiftData
import SwiftCipher

@main struct SwiftCipherExampleApp: App {
    var body: some Scene {
        WindowGroup {
            // The store is encrypted with a random key the package creates and keeps in the Keychain.
            ContentView()
                .cipherContainer(for: Schema([Note.self]), name: "notes")
        }
    }
}
