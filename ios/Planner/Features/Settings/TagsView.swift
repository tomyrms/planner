import SwiftUI
import Observation

@Observable
final class TagCatalogStore {
    private(set) var tags: [TagItem] = []
    private(set) var loaded = false
    private(set) var failed = false

    func observe(_ repository: TaskRepository) async {
        loaded = false
        failed = false
        do {
            for try await rows in try repository.observeTags() {
                try Task.checkCancellation()
                tags = rows
                loaded = true
            }
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            failed = true
        }
    }
}

struct TagsView: View {
    @Environment(AppServices.self) private var services
    @State private var catalogue = TagCatalogStore()
    @State private var retryId = UUID()
    @State private var editing: TagEditTarget?
    @State private var operation: Task<Void, Never>?
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if catalogue.loaded {
                Section {
                    ForEach(catalogue.tags.filter { !$0.isDeleted }) { tag in
                        Button(tag.name) { editing = TagEditTarget(tag: tag) }
                            .foregroundStyle(.primary)
                            .accessibilityHint("Renommer ce tag")
                            .contextMenu {
                                Button("Renommer", systemImage: "pencil") { editing = TagEditTarget(tag: tag) }
                                Button("Supprimer", systemImage: "trash", role: .destructive) { setDeleted(tag, true) }
                            }
                            .swipeActions {
                                Button("Supprimer", role: .destructive) { setDeleted(tag, true) }
                            }
                    }
                    if catalogue.tags.allSatisfy(\.isDeleted) {
                        Text("Aucun tag pour le moment.").foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Un tag peut être partagé par plusieurs tâches. Le supprimer ne supprime aucune tâche.")
                }
                let deleted = catalogue.tags.filter(\.isDeleted)
                if !deleted.isEmpty {
                    Section("Tags supprimés") {
                        ForEach(deleted) { tag in
                            HStack {
                                Text(tag.name).foregroundStyle(.secondary)
                                Spacer()
                                Button("Restaurer") { setDeleted(tag, false) }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Restaurer le tag \(tag.name)")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Tags")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Créer un tag", systemImage: "plus") { editing = TagEditTarget(tag: nil) }
                    .disabled(!catalogue.loaded || busy || catalogue.tags.filter { !$0.isDeleted }.count >= 200)
            }
        }
        .disabled(busy)
        .overlay { TagCatalogStatus(store: catalogue) { retryId = UUID() } }
        .sheet(item: $editing) { target in TagEditorView(tag: target.tag) }
        .task(id: retryId) { await catalogue.observe(services.tasks) }
        .onDisappear { operation?.cancel(); operation = nil }
        .alert("Modification impossible", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func setDeleted(_ tag: TagItem, _ deleted: Bool) {
        guard !busy else { return }
        busy = true
        operation = Task {
            defer { busy = false; operation = nil }
            do { try await services.tasks.setTagDeleted(tag.id, deleted) }
            catch {
                guard !Task.isCancelled else { return }
                errorMessage = (error as? TaskDetailsError)?.errorDescription ?? "Le tag n’a pas pu être enregistré sur cet iPhone."
            }
        }
    }
}

struct TagPickerView: View {
    @Binding var selection: Set<String>
    @Environment(AppServices.self) private var services
    @State private var catalogue = TagCatalogStore()
    @State private var retryId = UUID()
    @State private var editing: TagEditTarget?

    var body: some View {
        List {
            Section {
                ForEach(catalogue.tags.filter { !$0.isDeleted || selection.contains($0.id) }) { tag in
                    Toggle(isOn: binding(for: tag.id)) {
                        VStack(alignment: .leading) {
                            Text(tag.name)
                            if tag.isDeleted { Text("Tag supprimé").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .disabled(!selection.contains(tag.id) && (selectedActiveCount >= 10 || tag.isDeleted))
                }
                ForEach(selection.subtracting(Set(catalogue.tags.map(\.id))).sorted(), id: \.self) { id in
                    Toggle("Tag indisponible sur cet iPhone", isOn: binding(for: id))
                }
                if catalogue.loaded && catalogue.tags.isEmpty { Text("Créez un tag pour le choisir ici.").foregroundStyle(.secondary) }
            } footer: {
                Text("\(selectedActiveCount) sur 10 tags actifs sélectionnés. Le choix sera enregistré avec la tâche. Les liens vers les tags supprimés sont conservés pour leur restauration.")
            }
        }
        .navigationTitle("Tags de la tâche")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Créer un tag", systemImage: "plus") { editing = TagEditTarget(tag: nil) }
                    .disabled(!catalogue.loaded || catalogue.tags.filter { !$0.isDeleted }.count >= 200)
            }
        }
        .overlay { TagCatalogStatus(store: catalogue) { retryId = UUID() } }
        .task(id: retryId) { await catalogue.observe(services.tasks) }
        .sheet(item: $editing) { target in
            TagEditorView(tag: target.tag) { id in
                if selectedActiveCount < 10 { selection.insert(id) }
            }
        }
    }

    private var selectedActiveCount: Int {
        let deleted = Set(catalogue.tags.filter(\.isDeleted).map(\.id))
        return selection.subtracting(deleted).count
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(get: { selection.contains(id) }, set: { selected in
            if selected { selection.insert(id) } else { selection.remove(id) }
        })
    }
}

private struct TagCatalogStatus: View {
    let store: TagCatalogStore
    let retry: () -> Void
    var body: some View {
        if store.failed {
            ContentUnavailableView {
                Label("Lecture impossible", systemImage: "exclamationmark.triangle")
            } description: { Text("Le catalogue n’a pas pu être lu sur cet iPhone.") }
            actions: { Button("Réessayer", action: retry) }
        } else if !store.loaded { ProgressView("Lecture des tags…") }
    }
}

private struct TagEditTarget: Identifiable {
    let id = UUID()
    let tag: TagItem?
}

private struct TagEditorView: View {
    let tag: TagItem?
    var onSaved: ((String) -> Void)? = nil
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var saving = false
    @State private var operation: Task<Void, Never>?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nom", text: $name)
                } footer: { Text("Jusqu’à 50 caractères. Les accents distinguent les noms ; les majuscules ne les distinguent pas.") }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle(tag == nil ? "Nouveau tag" : "Renommer le tag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer", action: save)
                        .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count > 50)
                }
            }
            .interactiveDismissDisabled(saving)
            .onAppear { name = tag?.name ?? "" }
            .onDisappear { operation?.cancel(); operation = nil }
        }
    }

    private func save() {
        guard !saving else { return }
        saving = true
        operation = Task {
            defer { saving = false; operation = nil }
            do {
                let id: String
                if let tag { try await services.tasks.renameTag(tag.id, name: name); id = tag.id }
                else { id = try await services.tasks.createTag(name: name) }
                guard !Task.isCancelled else { return }
                onSaved?(id)
                dismiss()
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = (error as? TaskDetailsError)?.errorDescription ?? "Le tag n’a pas pu être enregistré sur cet iPhone."
            }
        }
    }
}
