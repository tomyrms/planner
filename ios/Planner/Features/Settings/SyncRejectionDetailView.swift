import SwiftUI

/// A rejection remains evidence until explicitly ignored. Saving a correction only proves a local
/// commit and must not hide the original failure before the server accepts the new command.
struct SyncRejectionDetailView: View {
    let rejection: SyncQueueRepository.Rejection
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var intent: SyncRejectionIntent?
    @State private var currentTask: TaskItem?
    @State private var cause: SyncQueueRepository.Rejection?
    @State private var editor: EditorRequest?
    @State private var preparation: Task<Void, Never>?
    @State private var ignoring: Task<Void, Never>?
    @State private var confirmingIgnore = false
    @State private var errorMessage: String?
    @State private var correctionSaved = false
    @State private var loaded = false

    private struct EditorRequest: Identifiable {
        let id = UUID()
        let mode: TaskEditorView.Mode
    }

    var body: some View {
        Form {
            Section {
                Text(intent?.actionTitle ?? RejectionText.title(for: rejection)).font(.headline)
                Text(RejectionText.reason(for: rejection.code))
                if let date = rejection.rejectedAt {
                    Text(date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                }
            } header: {
                Text("Non accepté par le serveur")
            } footer: {
                Text("Les valeurs visibles dans l’app peuvent encore changer lors de la synchronisation. Le rejet ne sera pas renvoyé automatiquement.")
            }
            if let cause {
                Section("Demande précédente refusée") {
                    NavigationLink {
                        SyncRejectionDetailView(rejection: cause)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(RejectionText.title(for: cause))
                            Text(RejectionText.reason(for: cause.code)).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            } else if intent?.dependsOn != nil {
                Section {
                    Text("Cette demande dépendait d’une modification précédente. Son rejet n’est plus disponible sur cet iPhone.")
                }
            }
            Section("Intention conservée") {
                if !loaded {
                    ProgressView("Lecture…")
                } else if let intent {
                    if intent.fields.isEmpty {
                        Text("Cette action ne contenait aucun champ supplémentaire.").foregroundStyle(.secondary)
                    }
                    ForEach(intent.fields) { field in
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text(field.title).font(.subheadline).foregroundStyle(.secondary)
                            Text(field.value).textSelection(.enabled)
                        }
                        .accessibilityElement(children: .combine)
                    }
                } else {
                    Text("Les valeurs de cette ancienne demande ne sont pas disponibles ou ne peuvent pas être lues. Le motif du rejet reste conservé.")
                }
            }
            Section {
                if correctionSaved {
                    Label("Nouvelle correction enregistrée sur cet iPhone.", systemImage: "checkmark.circle")
                    Text("La synchronisation doit encore confirmer son résultat. Le rejet initial reste conservé jusqu’à Ignorer.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if intent?.supportsEditor == true {
                    Button("Réessayer autrement", systemImage: "pencil") { prepareEditor() }
                        .disabled(preparation != nil)
                    if preparation != nil { ProgressView("Préparation de l’éditeur…") }
                    if intent?.type == "task.create" {
                        Text("Ouvre un brouillon prérempli. Ajouter créera une nouvelle tâche.").font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Refaites cette action depuis l’objet concerné après avoir vérifié sa version actuelle.")
                }
                if let currentTask {
                    Button(currentTask.isDeleted ? "Ouvrir la tâche dans la Corbeille" : "Ouvrir la tâche actuelle") {
                        editor = EditorRequest(mode: .edit(currentTask))
                    }
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.orange) }
            } footer: {
                Text("Les valeurs conservées sont incluses dans l’export local, disponible dans Réglages > Données.")
            }
            Section {
                Button("Ignorer ce rejet", role: .destructive) { confirmingIgnore = true }
                    .disabled(ignoring != nil || preparation != nil)
            }
        }
        .navigationTitle("Modification refusée")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            intent = SyncRejectionIntent(rejection: rejection)
            if intent?.aggregateType == "task" || (intent == nil && !rejection.commandType.hasPrefix("project.")) {
                currentTask = try? await services.tasks.task(id: rejection.aggregateId)
            }
            if let id = intent?.dependsOn, id.lowercased() != rejection.id.lowercased() {
                cause = try? await services.queue.rejection(id: id)
            }
            loaded = true
        }
        .sheet(item: $editor) { request in
            TaskEditorView(mode: request.mode, onSaved: {
                switch request.mode {
                case .retryCreate, .retryPatch: correctionSaved = true
                case .create, .edit: break
                }
            })
        }
        .confirmationDialog("Ignorer ce rejet ?", isPresented: $confirmingIgnore, titleVisibility: .visible) {
            Button("Ignorer et retirer de la liste", role: .destructive) { ignore() }
            Button("Conserver", role: .cancel) {}
        } message: {
            Text("Ce rejet et son intention seront retirés de la liste. Cette action ne modifie pas la tâche et ne renvoie aucune demande.")
        }
        .onDisappear {
            preparation?.cancel()
            ignoring?.cancel()
        }
    }

    private func prepareEditor() {
        guard preparation == nil, let intent else { return }
        errorMessage = nil
        preparation = Task {
            defer { preparation = nil }
            do {
                if intent.type == "task.create" {
                    let draft = try intent.prefilledDraft()
                    try Task.checkCancellation()
                    editor = EditorRequest(mode: .retryCreate(draft))
                } else {
                    guard let task = try await services.tasks.task(id: intent.aggregateId) else { throw SyncRejectionIntent.PreparationError.missingTask }
                    guard !task.isDeleted else { throw SyncRejectionIntent.PreparationError.deletedTask }
                    let base = TaskDraft(task: task, reminder: services.agenda.reminder(of: task.id))
                    let draft = try intent.prefilledDraft(current: base)
                    try Task.checkCancellation()
                    currentTask = task
                    editor = EditorRequest(mode: .retryPatch(task, base: base, draft: draft, fields: intent.patchFields))
                }
            } catch is CancellationError {
                // Closing this view does not enqueue or erase anything.
            } catch let error as SyncRejectionIntent.PreparationError {
                errorMessage = error.message
            } catch {
                errorMessage = "La tâche n’a pas pu être relue. Réessayez ; l’intention refusée est conservée."
            }
        }
    }

    private func ignore() {
        guard ignoring == nil else { return }
        ignoring = Task {
            defer { ignoring = nil }
            do {
                try Task.checkCancellation()
                try await services.queue.dismiss(rejection)
                dismiss()
            } catch is CancellationError {
            } catch {
                errorMessage = "Le rejet n’a pas pu être retiré. Réessayez."
            }
        }
    }
}
