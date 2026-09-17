import SwiftUI
import UniformTypeIdentifiers

/// Old intentions remain accessible after choosing a clean replica. Export does not replay them.
struct SyncRecoveryArchivesView: View {
    @Environment(AppModel.self) private var app
    @State private var archives: [RecoveryJournal] = []
    @State private var loading = true
    @State private var preparation: Task<Void, Never>?
    @State private var document: LocalExportDocument?
    @State private var filename = "planner-recuperation"
    @State private var exporting = false
    @State private var message: String?

    var body: some View {
        List {
            Section {
                if loading { ProgressView("Lecture des archives…") }
                else if archives.isEmpty { Text("Aucune récupération terminée sur cet iPhone.").foregroundStyle(.secondary) }
                ForEach(archives, id: \.id) { journal in
                    Button { prepare(journal) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(journal.createdAt.formatted(date: .abbreviated, time: .shortened))
                            Text(journal.choice == .newReplica ? "Ancienne copie locale · enregistrer le JSON" : "Avant réappairage · enregistrer le JSON")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(preparation != nil || exporting)
                }
            } footer: {
                Text("Ces archives contiennent les tâches, textes et commandes qui étaient présents avant la récupération. Enregistrez-les dans Fichiers pour les consulter. Aucun changement n’est importé ni renvoyé automatiquement.")
            }
            if preparation != nil { ProgressView("Vérification de l’archive…") }
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle("Archives de récupération")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            defer { loading = false }
            do { archives = try await app.recoveryArchives() }
            catch { message = "Les archives n’ont pas pu être lues. Les fichiers sont conservés ; réessayez." }
        }
        .onDisappear { preparation?.cancel(); preparation = nil }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: filename) { result in
            document = nil
            switch result {
            case .success: message = "Copie enregistrée dans Fichiers."
            case .failure(let error):
                if (error as NSError).code != CocoaError.Code.userCancelled.rawValue {
                    message = "L’enregistrement n’a pas abouti. L’archive reste conservée dans l’app."
                }
            }
        }
    }

    private func prepare(_ journal: RecoveryJournal) {
        guard preparation == nil, let proof = journal.archive else { return }
        message = nil
        filename = "planner-recuperation-" + String(Timestamp.format(journal.createdAt).prefix(10))
        preparation = Task {
            defer { preparation = nil }
            do {
                let data = try await app.recoveryArchiveData(proof)
                try Task.checkCancellation()
                document = LocalExportDocument(data: data)
                exporting = true
            } catch is CancellationError {
                // Only the file picker preparation is cancelled, never the retained archive.
            } catch {
                message = "L’archive n’a pas pu être vérifiée. Aucun fichier local n’a été supprimé."
            }
        }
    }
}
