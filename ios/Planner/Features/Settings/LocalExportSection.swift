import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// An in-memory JSON document; only the user's file-exporter choice writes it outside the app.
nonisolated struct LocalExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct LocalExportSection: View {
    @Environment(AppServices.self) private var services
    @State private var preparation: Task<Void, Never>?
    @State private var document: LocalExportDocument?
    @State private var presenting = false
    @State private var filename = "planner-iphone-export"
    @State private var status: String?
    @State private var errorMessage: String?

    var body: some View {
        Section {
            Button(action: prepare) {
                HStack {
                    Label("Exporter les données de cet iPhone", systemImage: "square.and.arrow.up")
                    if preparation != nil { Spacer(); ProgressView().accessibilityLabel("Préparation de l’export") }
                }
            }
            .disabled(preparation != nil || presenting)
            if let status { Text(status).font(.footnote).foregroundStyle(.secondary) }
            if let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(.red).accessibilityAddTraits(.isStaticText) }
        } header: {
            Text("Données")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Enregistre un fichier JSON avec les tâches, conversations, textes en cours et modifications en attente. Choisissez son emplacement dans Fichiers.")
                if services.sync.hasSynced != true {
                    Text("La première synchronisation n’est pas terminée : certaines données du serveur peuvent manquer.")
                } else {
                    Text("Le fichier contient les données présentes sur cet iPhone au moment de l’export. Des changements récents du serveur peuvent manquer.")
                }
                Text("L’audio n’est pas inclus. L’export fonctionne aussi hors ligne.")
            }
        }
        .fileExporter(isPresented: $presenting, document: document, contentType: .json, defaultFilename: filename) { result in
            document = nil
            switch result {
            case .success: status = "Export enregistré."
            case .failure(let error):
                if (error as NSError).code != CocoaError.Code.userCancelled.rawValue {
                    errorMessage = "Le fichier n’a pas pu être enregistré. Vos données restent sur cet iPhone."
                }
            }
        }
        .onDisappear {
            preparation?.cancel()
            preparation = nil
            // Keep the document alive while the system picker owns the export presentation.
        }
    }

    private func prepare() {
        guard preparation == nil else { return }
        status = nil
        errorMessage = nil
        let at = Date()
        let sync = services.sync
        let context = LocalExportContext(
            hasSynced: sync.hasSynced, lastSyncedAt: sync.lastSyncedAt,
            connection: connection(sync.block, connected: sync.isConnected),
            generationChanged: { if case .generationChanged = sync.block { return true }; return false }()
        )
        let voice = services.voice.draft.map {
            LocalExportVoiceText(
                transcriptionId: $0.transcriptionId, conversationId: $0.conversationId, state: $0.state.rawValue,
                transcript: $0.transcript, pendingAssistant: $0.handoff
            )
        }
        let drafts = LocalExportDrafts(
            assistantConversationId: services.assistant.conversationId,
            assistantText: services.assistant.draft.isEmpty ? nil : services.assistant.draft,
            pendingAssistant: services.assistant.pending, voice: voice
        )
        let repository = LocalExportRepository(db: services.db)
        filename = "planner-iphone-export-" + String(Timestamp.format(at).prefix(10))
        preparation = Task {
            defer { preparation = nil }
            do {
                let data = try await repository.data(context: context, drafts: drafts, at: at)
                try Task.checkCancellation()
                document = LocalExportDocument(data: data)
                presenting = true
            } catch is CancellationError {
                // Closing Settings abandons only this export, never data or the command queue.
            } catch {
                errorMessage = "L’export n’a pas pu être préparé. Réessayez ; vos données restent sur cet iPhone."
            }
        }
    }

    private func connection(_ block: SyncBlock?, connected: Bool) -> String {
        switch block {
        case .generationChanged: "generation_changed"
        case .pairingRequired: "pairing_required"
        case .updateRequired: "update_required"
        case .serverMisconfigured: "server_misconfigured"
        case .actionRequired: "action_required"
        case nil: connected ? "connected" : "offline"
        }
    }
}
