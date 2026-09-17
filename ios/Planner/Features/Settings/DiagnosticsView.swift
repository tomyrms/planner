import SwiftUI

/// Dates and operational state only: no task content, addresses, credentials or raw error messages.
struct DiagnosticsView: View {
    @Environment(AppServices.self) private var services
    @State private var store = DiagnosticsStore()
    @State private var refreshId = UUID()

    var body: some View {
        // Re-evaluate freshness while this screen stays open, without polling the server.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Form {
                requestSection
                if let snapshot = store.snapshot {
                    maintenanceSections(snapshot, at: context.date)
                    serverSection(snapshot)
                }
                localSyncSection
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: refreshId) { await store.refresh(using: services.api) }
        .onDisappear { store.cancel() }
    }

    private var requestSection: some View {
        Section {
            if store.isLoading {
                HStack {
                    ProgressView()
                    Text("Lecture du serveur…")
                }
                .accessibilityElement(children: .combine)
            }
            if let failure = store.failure {
                Text(failure.message).foregroundStyle(.orange)
                if store.snapshot != nil {
                    Text("Les informations ci-dessous proviennent de la dernière lecture réussie.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let date = Timestamp.parse(store.snapshot?.generatedAt) {
                value("Informations du serveur datées du", date: date)
            } else if !store.isLoading {
                Text("Aucune information du serveur disponible.").foregroundStyle(.secondary)
            }
            Button(store.failure == nil ? "Actualiser" : "Réessayer", systemImage: "arrow.clockwise") {
                refreshId = UUID()
            }
            .disabled(store.isLoading)
        } footer: {
            Text("Cet écran consulte le serveur. Il ne lance ni sauvegarde ni nettoyage.")
        }
    }

    @ViewBuilder
    private func maintenanceSections(_ snapshot: DiagnosticsSnapshot, at now: Date) -> some View {
        Section {
            maintenanceRow("Sauvegarde quotidienne", run: snapshot.maintenance.backup, at: now, maximumAge: 86_400)
            maintenanceRow("Vérification de sauvegarde", run: snapshot.maintenance.backupVerify, at: now, maximumAge: 86_400)
        } header: {
            Text("Sauvegardes")
        } footer: {
            Text("Après 24 h sans réussite, une sauvegarde ou sa vérification est signalée ancienne. Ces dates ne prouvent ni quel fichier a été vérifié, ni qu’une copie hors machine existe. La synchronisation ne remplace pas une sauvegarde.")
        }
        Section {
            maintenanceRow("Nettoyage quotidien", run: snapshot.maintenance.purge, at: now, maximumAge: 86_400)
            maintenanceRow("Nettoyage audio", run: snapshot.maintenance.audioCleanup, at: now, maximumAge: 3_600)
            maintenanceRow("Restauration du serveur", run: snapshot.maintenance.restore, at: now, maximumAge: nil)
        } header: {
            Text("Maintenance")
        } footer: {
            Text("Le nettoyage audio est prévu chaque heure. Une restauration absente est normale si le serveur n’a jamais été restauré.")
        }
    }

    private func maintenanceRow(_ title: String, run: DiagnosticsRun, at now: Date, maximumAge: TimeInterval?) -> some View {
        let state = run.state(at: now, maximumAge: maximumAge)
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title).font(.headline)
            Label(statusText(state, maximumAge: maximumAge), systemImage: statusIcon(state))
                .foregroundStyle(state == .failed || state == .stale || state == .inconsistent ? Color.orange : Color.secondary)
            if let date = run.succeededAt { Text("Dernière réussite : " + date.formatted(date: .abbreviated, time: .shortened)) }
            if let date = run.failedAt { Text("Dernier échec : " + date.formatted(date: .abbreviated, time: .shortened)) }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func serverSection(_ snapshot: DiagnosticsSnapshot) -> some View {
        Section {
            value("Réplication côté serveur", text: snapshot.sync == .provisioned ? "Configurée" : "Non configurée")
            value("Assistant", text: snapshot.assistant.status == .configured ? "Configuré" : "Désactivé")
            value("Transcription", text: snapshot.transcription.status == .configured ? "Configurée" : "Désactivée")
            DisclosureGroup("Détails techniques") {
                value("Version minimale de l’app", text: snapshot.minimumClientVersion)
                value("Génération du serveur", text: UUID(uuidString: snapshot.serverGeneration).map { String($0.uuidString.prefix(8)).lowercased() } ?? "Inconnue")
                value("Données à répliquer", text: snapshot.replicationLagBytes.flatMap { $0 >= 0 ? ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) : nil } ?? "Inconnu")
            }
        } header: {
            Text("Serveur")
        } footer: {
            Text("Une configuration présente ne prouve pas que le service répond. Le retard de réplication concerne le serveur, pas l’avancement de cet iPhone.")
        }
    }

    private var localSyncSection: some View {
        Section("Cet iPhone") {
            value("Synchronisation", text: syncText)
            value("Première synchronisation", text: services.sync.hasSynced.map { $0 ? "Terminée" : "Pas encore terminée" } ?? "État inconnu")
            if let date = services.sync.lastSyncedAt {
                value("Dernière synchronisation réussie", date: date)
            } else {
                value("Dernière synchronisation réussie", text: "Aucune date connue")
            }
        }
    }

    private var syncText: String {
        switch services.sync.block {
        case .generationChanged: "Suspendue — serveur restauré"
        case .pairingRequired: "Nouvel appairage nécessaire"
        case .updateRequired: "Mise à jour de l’app nécessaire"
        case .serverMisconfigured: "Configuration du serveur à vérifier"
        case .actionRequired: "Modifications à vérifier dans Réglages"
        case nil: services.sync.isConnected ? (services.sync.isTransferring ? "En cours" : "Connectée") : (services.sync.isConnecting ? "Connexion…" : "Hors ligne")
        }
    }

    private func value(_ title: String, date: Date) -> some View {
        value(title, text: date.formatted(date: .abbreviated, time: .shortened))
    }

    private func value(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func statusText(_ state: DiagnosticsRun.State, maximumAge: TimeInterval?) -> String {
        switch state {
        case .unknown: "Aucun résultat enregistré"
        case .inconsistent: "Dates incohérentes — état inconnu"
        case .failed: "Dernier passage en échec"
        case .stale: maximumAge == 3_600 ? "Aucune réussite depuis plus d’une heure" : "Aucune réussite depuis plus de 24 h"
        case .succeeded: maximumAge == nil ? "Réussite enregistrée" : "Réussite récente enregistrée"
        }
    }

    private func statusIcon(_ state: DiagnosticsRun.State) -> String {
        switch state {
        case .unknown: "questionmark.circle"
        case .inconsistent, .failed: "exclamationmark.triangle"
        case .stale: "clock.badge.exclamationmark"
        case .succeeded: "checkmark.circle"
        }
    }
}
