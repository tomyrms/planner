import SwiftUI

struct AssistantSettingsView: View {
    @Environment(AppServices.self) private var services
    @State private var autoTags = false
    @State private var loaded = false
    @State private var readFailed = false
    @State private var saving = false
    @State private var retryId = UUID()
    @State private var operation: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var pending = false
    @State private var rejected = false
    @State private var syncStateFailed = false

    var body: some View {
        Form {
            Section {
                Toggle("Tags automatiques", isOn: Binding(get: { autoTags }, set: { save($0) }))
                    .disabled(!loaded || readFailed || saving)
                if !loaded && !readFailed { ProgressView("Lecture du réglage…") }
                if readFailed {
                    Text("Le réglage n’a pas pu être lu sur cet iPhone.").foregroundStyle(.secondary)
                    Button("Réessayer") { retryId = UUID() }
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                if pending {
                    Label("Réglage enregistré sur cet iPhone, en attente de synchronisation.", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)
                }
                if rejected {
                    Text("Une modification de ce réglage a été refusée. Consultez Synchronisation dans Réglages.")
                        .foregroundStyle(.orange)
                }
                if syncStateFailed {
                    Text("L’état d’envoi de ce réglage n’a pas pu être vérifié.").foregroundStyle(.secondary)
                }
            } header: { Text("Nouvelles tâches créées avec l’assistant") }
            footer: {
                Text("Autorise l’assistant à choisir des tags pour les nouvelles tâches que vous lui demandez de créer. Désactivé par défaut. Les tâches existantes et les créations manuelles ne sont pas classées automatiquement.")
            }
        }
        .navigationTitle("Paramètres de l’assistant")
        .task(id: retryId) { await observe() }
        .task(id: services.sync.isTransferring) { await refreshSyncState() }
        .onDisappear { operation?.cancel(); operation = nil }
    }

    private func observe() async {
        loaded = false
        readFailed = false
        do {
            for try await values in try services.tasks.observeAutoTags() {
                try Task.checkCancellation()
                autoTags = values.first ?? false
                loaded = true
                await refreshSyncState()
            }
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            readFailed = true
        }
    }

    private func save(_ enabled: Bool) {
        guard loaded, !readFailed, !saving else { return }
        saving = true
        errorMessage = nil
        operation = Task {
            defer { saving = false; operation = nil }
            do {
                try await services.tasks.setAutoTags(enabled)
                guard !Task.isCancelled else { return }
                autoTags = enabled // The local transaction has committed; observation also reflects it.
                await refreshSyncState()
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = (error as? TaskDetailsError)?.errorDescription ?? "Le réglage n’a pas pu être enregistré sur cet iPhone."
            }
        }
    }

    private func refreshSyncState() async {
        do {
            let state = try await services.tasks.assistantSettingsSyncState()
            try Task.checkCancellation()
            pending = state.pending
            rejected = state.rejected
            syncStateFailed = false
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            syncStateFailed = true
        }
    }
}
