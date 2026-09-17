import SwiftUI

/// A failed local commit keeps the name and the sheet open.
struct ProjectEditorView: View {
    var project: ProjectItem?
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var prepared = false
    @State private var confirmingDelete = false
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var operation: Task<Void, Never>?
    @FocusState private var nameFocused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var valid: Bool { !trimmed.isEmpty && trimmed.utf16.count <= 200 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nom de la liste", text: $name, axis: .vertical)
                        .focused($nameFocused)
                } footer: {
                    if trimmed.utf16.count > 200 { Text("Le nom est trop long : 200 caractères maximum.") }
                }
                if project != nil {
                    Section {
                        Button("Supprimer la liste", role: .destructive) { confirmingDelete = true }
                    }
                }
                if let errorMessage {
                    Section { Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .disabled(saving)
            .navigationTitle(project == nil ? "Nouvelle liste" : "Modifier la liste")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(project == nil ? "Créer" : "Enregistrer") { save() }
                        .disabled(saving || !valid || (project != nil && trimmed == project?.name))
                }
            }
            .interactiveDismissDisabled(saving || trimmed != (project?.name ?? ""))
            .confirmationDialog("Supprimer cette liste ?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Déplacer les tâches dans Inbox") { save(deleting: .inbox) }
                Button("Mettre les tâches à la corbeille", role: .destructive) { save(deleting: .trash) }
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("Choisissez ce qu’il advient des tâches, y compris celles terminées. La liste restera restaurable dans la Corbeille pendant 30 jours.")
            }
            .onAppear {
                guard !prepared else { return }
                prepared = true
                name = project?.name ?? ""
                nameFocused = project == nil
            }
            .onDisappear { operation?.cancel() }
        }
    }

    private func save(deleting policy: ProjectTaskPolicy? = nil) {
        guard !saving else { return }
        let repository = services.tasks
        let name = trimmed
        saving = true
        errorMessage = nil
        operation = Task { @MainActor in
            defer { saving = false; operation = nil }
            do {
                try Task.checkCancellation()
                if let project {
                    if let policy { try await repository.deleteProject(project, policy: policy) }
                    else { try await repository.renameProject(project, name: name) }
                } else { try await repository.createProject(name: name) }
                dismiss()
            } catch is CancellationError {
            } catch {
                errorMessage = (error as? ProjectMutationError)?.errorDescription ?? "La liste n’a pas pu être enregistrée sur cet iPhone. Réessayez."
            }
        }
    }
}

struct DeletedProjectsSection: View {
    @Environment(AppServices.self) private var services
    @State private var projects: [ProjectItem] = []
    @State private var loaded = false
    @State private var failed = false
    @State private var retryId = UUID()
    @State private var restoring: String?
    @State private var operation: Task<Void, Never>?
    @State private var errorMessage: String?

    var body: some View {
        Section("Listes supprimées") {
            if failed {
                Text("Les listes supprimées n’ont pas pu être lues.")
                Button("Réessayer") { retryId = UUID() }
            } else if !loaded {
                ProgressView("Lecture des listes…")
            } else if projects.isEmpty {
                Text("Aucune liste supprimée.").foregroundStyle(.secondary)
            }
            ForEach(projects) { project in
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(project.name)
                    Button(restoring == project.id ? "Restauration…" : "Restaurer la liste") { restore(project) }
                        .disabled(restoring != nil)
                }
            }
        }
        .task(id: retryId) {
            failed = false
            do {
                for try await values in try services.tasks.observeProjects(deleted: true) {
                    try Task.checkCancellation()
                    projects = values
                    loaded = true
                }
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
        .onDisappear { operation?.cancel() }
        .alert("Restauration impossible", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func restore(_ project: ProjectItem) {
        guard restoring == nil else { return }
        restoring = project.id
        operation = Task { @MainActor in
            defer { restoring = nil; operation = nil }
            do {
                try Task.checkCancellation()
                try await services.tasks.restoreProject(project)
            } catch is CancellationError {
            } catch {
                errorMessage = (error as? ProjectMutationError)?.errorDescription ?? "La liste n’a pas pu être restaurée sur cet iPhone. Réessayez."
            }
        }
    }
}
