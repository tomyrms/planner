import SwiftUI

/// Réglages > Synchronisation (03_iOS/02_Local_Data_Sync.md, État de connexion), appareil et version.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var pendingCount = 0
    @State private var oldestPending: Date?
    @State private var generation: String?
    @State private var rejections: [SyncQueueRepository.Rejection] = []
    @State private var confirmingUnpair = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                syncSection
                SyncRecoverySection()
                if !rejections.isEmpty { rejectionsSection }
                LocalExportSection()
                Section {
                    NavigationLink { DiagnosticsView() } label: {
                        Label("Diagnostics", systemImage: "stethoscope")
                    }
                }
                Section("Personnalisation") {
                    NavigationLink { TagsView() } label: {
                        Label("Tags", systemImage: "tag")
                    }
                    NavigationLink { AssistantSettingsView() } label: {
                        Label("Assistant", systemImage: "text.bubble")
                    }
                }
                deviceSection
                aboutSection
            }
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
            .confirmationDialog("Déconnecter cet iPhone ?", isPresented: $confirmingUnpair, titleVisibility: .visible) {
                Button("Déconnecter et effacer les données locales", role: .destructive, action: unpair)
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("L’appareil est révoqué sur le serveur. Les tâches restent sur le serveur ; cet iPhone devra être appairé de nouveau.")
            }
            .alert("Action impossible", isPresented: hasError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .task { await refreshQueue() }
            .task { await observeRejections() }
        }
    }

    // MARK: - Sections

    private var syncSection: some View {
        Section("Synchronisation") {
            LabeledContent("État", value: stateText)
            if let block = services.sync.block {
                Text(explanation(of: block))
                    .foregroundStyle(.orange)
                if canRetry(block) {
                    Button("Réessayer") {
                        Task { await services.sync.retry() }
                    }
                }
            }
            if let lastSync = services.sync.lastSyncedAt {
                LabeledContent("Dernière synchronisation", value: lastSync.formatted(.relative(presentation: .named)))
            }
            LabeledContent("Modifications en attente", value: pendingText)
            if let generation {
                LabeledContent("Génération du serveur", value: String(generation.prefix(8)))
            }
        }
    }

    private var rejectionsSection: some View {
        Section {
            ForEach(rejections) { rejection in
                NavigationLink {
                    SyncRejectionDetailView(rejection: rejection)
                } label: {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(RejectionText.title(for: rejection))
                        Text(RejectionText.reason(for: rejection.code))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("À vérifier")
        } footer: {
            Text("Ouvrez une modification pour consulter ce qui a été refusé, puis la corriger ou l’ignorer.")
        }
    }

    private var deviceSection: some View {
        Section("Appareil") {
            LabeledContent("Serveur", value: services.session.apiBaseURL.host() ?? services.session.apiBaseURL.absoluteString)
            Button("Déconnecter cet iPhone", role: .destructive) { confirmingUnpair = true }
                .disabled(pendingCount > 0)
            if pendingCount > 0 {
                Text("Impossible tant que des modifications attendent d’être envoyées.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var aboutSection: some View {
        let info = BuildInfo.current
        return Section {
            LabeledContent("Version", value: "\(info.version) (\(info.build))")
            LabeledContent("iOS", value: info.systemVersion)
            LabeledContent("Modèle", value: info.hardwareModel)
        } header: {
            Text("À propos")
        } footer: {
            Text("Vos demandes écrites sont traitées par DeepSeek, vos messages vocaux transcrits par OpenAI.")
        }
    }

    // MARK: - State

    private var stateText: String {
        if services.sync.block != nil { return "Action requise" }
        let sync = services.sync
        if sync.isConnected { return sync.isTransferring ? "En cours" : "Connecté" }
        if sync.isConnecting { return "Connexion…" }
        return "Hors ligne"
    }

    private var pendingText: String {
        guard pendingCount > 0 else { return "Aucune" }
        var text = "\(pendingCount)"
        if let oldestPending {
            text += " · depuis " + oldestPending.formatted(.relative(presentation: .named))
        }
        return text
    }

    private var hasError: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func canRetry(_ block: SyncBlock) -> Bool {
        switch block {
        case .actionRequired, .serverMisconfigured: true
        case .generationChanged, .updateRequired, .pairingRequired: false
        }
    }

    private func explanation(of block: SyncBlock) -> String {
        switch block {
        case .generationChanged:
            "Le serveur a été restauré depuis une sauvegarde. Rien n’est envoyé ni effacé : les modifications de cet iPhone sont conservées en attendant la récupération."
        case .actionRequired(let status, let code):
            "Le serveur a refusé l’envoi (\(code ?? "HTTP \(status)")). Les modifications restent sur cet iPhone."
        case .updateRequired(let minimumVersion):
            "Cette version de l’app est trop ancienne\(minimumVersion.map { " (minimum \($0))" } ?? ""). Installez la dernière version."
        case .pairingRequired:
            "Cet iPhone n’est plus autorisé (révoqué ou session expirée). Les données locales sont conservées ; un nouvel appairage est nécessaire."
        case .serverMisconfigured:
            "Le serveur n’indique pas son adresse de synchronisation (PUBLIC_SYNC_URL)."
        }
    }

    private func refreshQueue() async {
        while !Task.isCancelled {
            if let summary = try? await services.queue.pending() {
                pendingCount = summary.count
                oldestPending = summary.oldest
            }
            generation = try? await services.queue.serverGeneration()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func observeRejections() async {
        do {
            for try await rows in try services.queue.observeRejections() {
                rejections = rows
            }
        } catch {}
    }

    private func unpair() {
        Task {
            do {
                try await app.unpair()
            } catch UnpairError.pendingCommands(let count) {
                errorMessage = "\(count) modification(s) attendent encore d’être envoyées."
            } catch {
                errorMessage = "La déconnexion n’a pas abouti."
            }
        }
    }
}

/// App texts for rejection codes (the server's message stays in English and is not shown).
enum RejectionText {
    static func title(for rejection: SyncQueueRepository.Rejection) -> String {
        switch rejection.commandType {
        case "task.create": "Création d’une tâche"
        case "task.patch": "Modification d’une tâche"
        case "task.complete": "Tâche terminée"
        case "task.reopen": "Tâche rouverte"
        case "task.delete": "Suppression d’une tâche"
        case "task.restore": "Restauration d’une tâche"
        case "project.create": "Création d’une liste"
        default: "Modification"
        }
    }

    static func reason(for code: String) -> String {
        switch code {
        case "TASK_DELETED": "La tâche avait été supprimée."
        case "ENTITY_NOT_FOUND", "ENTITY_PURGED": "La tâche n’existe plus sur le serveur."
        case "PROJECT_DELETED": "La liste avait été supprimée."
        case "REVISION_MISMATCH": "La tâche avait été modifiée ailleurs."
        case "DEPENDENCY_REJECTED": "Elle dépendait d’une modification refusée."
        case "VALIDATION_FAILED": "Valeurs refusées par le serveur."
        case "SERIES_COMMAND_REQUIRED": "Tâche répétée : modification à faire autrement."
        case "FORBIDDEN_REFERENCE": "Liste inconnue."
        default: "Refusée par le serveur (\(code))."
        }
    }
}
