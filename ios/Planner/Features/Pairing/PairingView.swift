import SwiftUI

/// Enrolment from the homelab console (ADR-026): one link carries the server address and the secret.
struct PairingView: View {
    @Environment(AppModel.self) private var app
    @State private var link = ""
    @State private var server = ""
    @State private var secret = ""
    @State private var manual = false
    @State private var pairing = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Sur le serveur, lancez `npm run admin -- pair --name \"iPhone\"`, puis collez ici le lien affiché. Il expire après 10 minutes.")
                }
                Section("Lien d’appairage") {
                    TextField("planner://pair?…", text: $link, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                }
                Section {
                    DisclosureGroup("Saisie manuelle", isExpanded: $manual) {
                        TextField("https://…", text: $server)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Secret d’appairage", text: $secret)
                    }
                }
                Section {
                    Button(action: pair) {
                        if pairing {
                            ProgressView()
                        } else {
                            Text("Appairer cet iPhone")
                        }
                    }
                    .disabled(pairing || request == nil)
                } footer: {
                    if request == nil && !(link.isEmpty && server.isEmpty) {
                        Text("Lien ou adresse invalide : le serveur doit être en HTTPS.")
                    }
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    Text("Vos demandes écrites sont traitées par DeepSeek, vos messages vocaux transcrits par OpenAI.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Appairage")
        }
    }

    private var request: PairingLink? {
        if !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return PairingLink(link: link)
        }
        return PairingLink(server: server, secret: secret)
    }

    private func pair() {
        guard let request else { return }
        pairing = true
        errorMessage = nil
        Task {
            defer { pairing = false }
            do {
                try await app.pair(with: request)
            } catch let error as APIError {
                errorMessage = PairingView.message(for: error)
            } catch {
                errorMessage = "L’appairage n’a pas pu être enregistré sur cet iPhone."
            }
        }
    }

    private static func message(for error: APIError) -> String {
        switch error {
        case .unauthorized:
            "Secret refusé : il est inconnu, déjà utilisé ou expiré. Générez un nouveau lien."
        case .http(429, _, _, _, _):
            "Trop d’essais. Réessayez dans quelques minutes."
        case .http(426, _, _, _, _):
            "Cette version de l’app est trop ancienne pour ce serveur."
        case .http(let status, let code, _, _, _):
            "Appairage refusé (\(code ?? "HTTP \(status)"))."
        case .transport:
            "Serveur injoignable depuis cet iPhone. Vérifiez l’adresse et la connexion."
        case .invalidResponse:
            "Réponse inattendue : est-ce bien l’adresse du serveur Planner ?"
        }
    }
}
