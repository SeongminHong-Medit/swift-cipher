import SwiftUI
import SwiftCipher

struct KeychainSetupView: View {
    let onSave: @MainActor (String) -> Void

    @State private var passphrase: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            Text("Set Up Encryption")
                .font(.title)

            SecureField("Enter passphrase", text: $passphrase)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            Button("Unlock") {
                savePassphrase()
            }
            .disabled(passphrase.isEmpty)
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
    }

    private func savePassphrase() {
        do {
            try CipherKeychain.store(passphrase: passphrase, for: "com.example.swift-cipher-notes")
            onSave(passphrase)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
