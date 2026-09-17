import SwiftUI
import UniformTypeIdentifiers

/// Entry in Settings. The app then owns the flow, so closing a sheet cannot reopen editing mid-switch.
struct SyncRecoverySection: View {
    @Environment(AppModel.self) private var app
    @Environment(AppServices.self) private var services

    var body: some View {
        Section {
            if needsRecovery {
                Button("Récupérer la synchronisation", systemImage: "arrow.triangle.2.circlepath") { app.prepareRecovery() }
                    .disabled(app.recovery.isBusy)
            }
            NavigationLink("Archives de récupération", systemImage: "archivebox") { SyncRecoveryArchivesView() }
        } header: {
            Text("Récupération")
        } footer: {
            if needsRecovery {
                Text("Conserve d’abord une archive des données et modifications locales, puis vérifie le nouvel appairage.")
            }
        }
    }

    private var needsRecovery: Bool {
        switch services.sync.block {
        case .pairingRequired, .generationChanged: true
        default: false
        }
    }
}

struct SyncRecoveryView: View {
    @Environment(AppModel.self) private var app
    @State private var link = ""
    @State private var confirmingNewReplica = false
    @State private var exporting = false
    @State private var exportRequested = false
    @State private var exportMessage: String?

    private var recovery: SyncRecoveryState { app.recovery }
    private var journal: RecoveryJournal? { recovery.journal }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Vos données restent sur cet iPhone. La synchronisation et les envois à l’assistant sont suspendus pendant la récupération.")
                    if let server = journal?.sourceIdentity.serverURL.host() {
                        LabeledContent("Serveur", value: server)
                    }
                }
                archiveSection
                if journal?.stage == .archiveReady || journal?.stage == .candidateReady { pairingSection }
                if journal?.stage == .candidateReady { choiceSection }
                if journal?.switchWasConfirmed == true {
                    Section {
                        Text("Le choix est enregistré. La reprise peut être terminée même après la fermeture de l’app.")
                        Button("Terminer la récupération") { app.resumeRecovery() }
                            .disabled(recovery.isBusy)
                        if journal?.stage == .switchPrepared || journal?.stage == .replicaPrepared {
                            Button("Utiliser un nouveau lien d’appairage") { app.resetRecoveryCandidate() }
                                .disabled(recovery.isBusy)
                        }
                    }
                }
                if recovery.isBusy {
                    Section { ProgressView("Préparation et vérification…") }
                }
                if let message = recovery.message {
                    Section { Text(message).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Récupération")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
            .confirmationDialog("Utiliser une nouvelle copie locale ?", isPresented: $confirmingNewReplica, titleVisibility: .visible) {
                Button("Créer la nouvelle copie") { app.confirmRecovery(newReplica: true) }
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("L’ancienne copie et son archive restent sur cet iPhone. Ses commandes et demandes à l’assistant ne seront pas renvoyées. Vérifiez l’archive pour reporter manuellement les changements souhaités.")
            }
            .fileExporter(isPresented: $exporting,
                          document: recovery.archiveData.map { LocalExportDocument(data: $0) },
                          contentType: .json, defaultFilename: "planner-recuperation") { result in
                switch result {
                case .success: exportMessage = "Copie enregistrée dans Fichiers."
                case .failure(let error):
                    if (error as NSError).code != CocoaError.Code.userCancelled.rawValue {
                        exportMessage = "L’enregistrement dans Fichiers a échoué. L’archive vérifiée reste conservée dans l’app."
                    }
                }
            }
            .onChange(of: recovery.isBusy) { _, busy in
                guard !busy, exportRequested else { return }
                exportRequested = false
                if recovery.archiveData != nil { exporting = true }
            }
        }
    }

    private var archiveSection: some View {
        Section {
            if let archive = journal?.archive {
                Label("Archive locale vérifiée", systemImage: "checkmark.circle")
                Text(ByteCountFormatter.string(fromByteCount: Int64(archive.byteCount), countStyle: .file))
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Enregistrer une copie dans Fichiers", systemImage: "square.and.arrow.up") {
                    if recovery.archiveData != nil { exporting = true }
                    else { exportRequested = true; app.loadRecoveryArchive() }
                }
                .disabled(recovery.isBusy)
                if journal?.stage == .archiveReady {
                    Button("Vérifier et recréer l’archive") { app.prepareRecovery() }
                        .disabled(recovery.isBusy)
                }
            } else {
                Button("Préparer et vérifier l’archive") { app.prepareRecovery() }
                    .disabled(recovery.isBusy)
            }
            if let exportMessage { Text(exportMessage).font(.footnote).foregroundStyle(.secondary) }
        } header: {
            Text("1. Conserver la copie locale")
        } footer: {
            Text("Tâches, conversations, textes en cours et commandes en attente sont conservés. L’audio reste temporaire sur cet iPhone, pendant 24 h au maximum ; il n’est pas inclus dans l’archive.")
        }
    }

    private var pairingSection: some View {
        Section {
            SecureField("Coller le lien planner://pair?…", text: $link)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .privacySensitive()
            Button("Vérifier le nouvel appairage") {
                guard let parsed = PairingLink(link: link) else { return }
                link = ""
                app.verifyRecoveryLink(parsed)
            }
            .disabled(recovery.isBusy || PairingLink(link: link) == nil)
        } header: {
            Text("2. Vérifier le serveur et l’utilisateur")
        } footer: {
            Text("Générez un nouveau lien d’appairage sur le serveur habituel. Il sert uniquement à préparer cette reprise et n’est pas enregistré dans l’archive.")
        }
    }

    @ViewBuilder
    private var choiceSection: some View {
        Section("3. Choisir la reprise") {
            switch recovery.decision {
            case .reuseReplica:
                Text("Même serveur, même utilisateur, même génération. Les données locales et leurs identifiants peuvent être conservés.")
                Button("Reprendre avec les modifications conservées") { app.confirmRecovery(newReplica: false) }
                    .disabled(recovery.isBusy)
            case .newReplicaRequired(let reason):
                Text(reason == .generationChanged
                     ? "Le serveur a été restauré. Les anciennes commandes ne peuvent pas être rejouées sur cette génération."
                     : "Cette ancienne installation ne permet pas de prouver l’identité de sa copie locale. Ses commandes ne seront pas rejouées.")
                Button("Utiliser une nouvelle copie locale") { confirmingNewReplica = true }
                    .disabled(recovery.isBusy)
            case nil:
                Text("Un appairage vérifié est nécessaire pour poursuivre.")
            }
        }
    }
}
