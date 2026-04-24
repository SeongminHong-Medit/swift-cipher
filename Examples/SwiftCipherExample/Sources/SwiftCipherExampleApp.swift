import SwiftUI
import SwiftData
import SwiftCipher

@main struct SwiftCipherExampleApp: App {
    @State private var passphrase: String? = try? CipherKeychain.retrieve(for: "com.example.swift-cipher-notes")

    var body: some Scene {
        WindowGroup {
            if let passphrase {
                ContentView()
                    .cipherContainer(
                        for: Schema([Note.self]),
                        encryptionKey: .passphrase(passphrase),
                        name: "notes"
                    )
            } else {
                KeychainSetupView(onSave: { passphrase = $0 })
            }
        }
    }
}
