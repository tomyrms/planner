import SwiftUI

/// A tag is a filter across lists. Its name/availability and membership follow local changes.
struct TagTasksView: View {
    let tag: TagItem
    @Environment(AppServices.self) private var services
    @State private var tasks: [TaskItem] = []
    @State private var loaded = false
    @State private var failed = false
    @State private var retryId = UUID()

    private var currentTag: TagItem? { services.tagDirectory.tag(id: tag.id) }
    private var unavailable: Bool { services.tagDirectory.loaded && currentTag == nil }
    private var readFailed: Bool { failed || services.tagDirectory.failed }
    private var active: [TaskItem] { tasks.filter { !$0.isCompleted } }
    private var completed: [TaskItem] { tasks.filter(\.isCompleted) }

    var body: some View {
        List {
            SyncNotice()
            if readFailed {
                Section {
                    Text("Les tâches ou les tags n’ont pas pu être lus sur cet iPhone.")
                    Button("Réessayer", systemImage: "arrow.clockwise") { retry() }
                        .disabled(services.isRecoverySuspended)
                }
            } else if unavailable {
                ContentUnavailableView("Tag indisponible", systemImage: "tag.slash", description: Text("Il a été supprimé ou n’est plus disponible sur cet iPhone."))
            } else if !loaded || !services.tagDirectory.loaded {
                ProgressView("Lecture des tâches…")
            } else if tasks.isEmpty {
                ContentUnavailableView("Aucune tâche avec ce tag", systemImage: "tag", description: Text("Ajoutez ce tag depuis une tâche pour la retrouver ici."))
            } else {
                if !active.isEmpty {
                    Section("Actives") {
                        ForEach(active) { TaskRow(task: $0, context: .tag) }
                    }
                }
                if !completed.isEmpty {
                    Section("Terminées") {
                        ForEach(completed) { TaskRow(task: $0, context: .completed) }
                    }
                }
            }
        }
        .navigationTitle(currentTag?.name ?? tag.name)
        .scrollDismissesKeyboard(.interactively)
        .task(id: retryId) {
            loaded = false
            failed = false
            do {
                for try await rows in try services.tasks.observeTasks(tagId: tag.id) {
                    try Task.checkCancellation()
                    tasks = rows
                    loaded = true
                }
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                failed = true
            }
        }
    }

    private func retry() {
        if services.tagDirectory.failed { services.tagDirectory.start(services.tasks) }
        retryId = UUID()
    }
}

struct TagCatalogueLabel: View {
    let name: String
    let activeCount: Int
    @Environment(\.dynamicTypeSize) private var dynamicType

    var body: some View {
        let layout = dynamicType.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.xs)) : AnyLayout(HStackLayout(spacing: Spacing.md))
        layout {
            Label(name, systemImage: "tag")
                .fixedSize(horizontal: false, vertical: true)
            if !dynamicType.isAccessibilitySize { Spacer(minLength: Spacing.sm) }
            Text("\(activeCount)").foregroundStyle(.secondary).monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(activeCount) \(activeCount == 1 ? "tâche active" : "tâches actives")")
    }
}
