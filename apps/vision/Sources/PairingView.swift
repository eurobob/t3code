import SwiftUI

/// Direct pairing, and currently the only path that actually works.
///
/// T3 Connect sign-in fails against the production Clerk instance because
/// ClerkKit redirects to `t3code://clerk-callback`, which is not in that
/// instance's authorised redirect URIs — the team builds against a development
/// instance (`pk_test_…`) where it is. Allowlisting it is a Clerk dashboard
/// change, so until then this is how you get connected.
///
/// Pairing is one-time regardless: the environment is persisted and the
/// credential lives in the Keychain, so `AppModel.restore()` reconnects on
/// later launches without asking again.
struct PairingView: View {
    @SwiftUI.Environment(AppModel.self) private var model
    @State private var pairingURL = ""

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("Pair with a server")
                    .font(.title.weight(.semibold))
                Text("Run `npx t3 pair` on your server and paste the pairing URL.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Vision Pro gives apps no camera access, so the QR code the CLI
            // prints is unusable here — the URL beside it is the whole flow.
            TextField("https://…/pair?code=…", text: $pairingURL)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .frame(maxWidth: 520)
                .onSubmit(pair)

            Button("Pair", action: pair)
                .buttonStyle(.borderedProminent)
                .disabled(trimmed.isEmpty)
        }
        .padding(32)
    }

    private var trimmed: String {
        pairingURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func pair() {
        guard !trimmed.isEmpty else { return }
        Task { await model.pair(pairingURL: trimmed) }
    }
}
