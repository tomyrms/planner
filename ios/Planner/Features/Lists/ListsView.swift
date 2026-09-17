import SwiftUI

/// Listes: Inbox, À venir, the user's lists, Terminées, Corbeille; search covers tasks and lists.
struct ListsView: View {
    @Environment(AppServices.self) private var services
    @State private var query = ""
    @State private var creatingTask = false
    @State private var showingSettings = false
    @State private var namingList = false
    @State private var editingList: ProjectItem?

    var body: some View {
        NavigationStack {
            Group {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    lists
                } else {
                    SearchResultsView(query: query)
                }
            }
            .navigationTitle("Listes")
            .searchable(text: $query, prompt: "Tâches et listes")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Réglages", systemImage: "gearshape") { showingSettings = true }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Ajouter une tâche", systemImage: "plus") { creatingTask = true }
                }
            }
            .sheet(isPresented: $creatingTask) {
                TaskEditorView(mode: .create(projectId: nil, schedule: nil))
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .sheet(isPresented: $namingList) { ProjectEditorView() }
            .sheet(item: $editingList) { ProjectEditorView(project: $0) }
        }
    }

    private var lists: some View {
        List {
            SyncNotice()
            Section {
                NavigationLink {
                    TaskListScreen(title: "Inbox", filter: .inbox, context: .list)
                } label: {
                    LabeledContent {
                        if services.directory.inboxCount > 0 { Text("\(services.directory.inboxCount)") }
                    } label: {
                        Label("Inbox", systemImage: "tray")
                    }
                }
                NavigationLink {
                    UpcomingView()
                } label: {
                    Label("À venir", systemImage: "calendar")
                }
            }
            Section("Mes listes") {
                ForEach(services.directory.projects) { project in
                    NavigationLink {
                        TaskListScreen(title: project.name, filter: .project(project.id), context: .list, projectId: project.id)
                    } label: {
                        LabeledContent {
                            if project.activeTaskCount > 0 { Text("\(project.activeTaskCount)") }
                        } label: {
                            Label(project.name, systemImage: "list.bullet")
                        }
                    }
                    .contextMenu {
                        Button("Modifier la liste", systemImage: "pencil") { editingList = project }
                    }
                }
                Button("Nouvelle liste", systemImage: "plus") { namingList = true }
            }
            Section {
                NavigationLink {
                    TaskListScreen(title: "Terminées", filter: .completed, context: .completed)
                } label: {
                    Label("Terminées", systemImage: "checkmark.circle")
                }
                NavigationLink {
                    TaskListScreen(title: "Corbeille", filter: .trash, context: .trash)
                } label: {
                    Label("Corbeille", systemImage: "trash")
                }
            }
        }
    }

}

/// A list of tasks observed from the local database.
struct TaskListScreen: View {
    let title: String
    let filter: TaskFilter
    let context: TaskRowContext
    var projectId: String?
    var embedded = false
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var tasks: [TaskItem] = []
    @State private var loaded = false
    @State private var creating = false
    @State private var readFailed = false
    @State private var retryId = UUID()
    @State private var editingList: ProjectItem?

    private var project: ProjectItem? { services.directory.projects.first { $0.id == projectId } }

    private struct ObservationKey: Hashable {
        let filter: TaskFilter
        let retryId: UUID
    }

    var body: some View {
        List {
            if embedded { SyncNotice() }
            if context == .trash { DeletedProjectsSection() }
            ForEach(tasks) { task in
                TaskRow(task: task, context: context)
            }
            if context == .trash, !tasks.isEmpty {
                Section {
                    Text("Les tâches supprimées restent 30 jours dans la corbeille.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .overlay {
            if readFailed {
                ContentUnavailableView {
                    Label("Lecture impossible", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("Les tâches n’ont pas pu être lues sur cet iPhone.")
                } actions: {
                    Button("Réessayer") { retryId = UUID() }
                }
            } else if !loaded {
                ProgressView("Lecture des tâches…")
            } else if context != .trash && tasks.isEmpty && (!embedded || (services.sync.hasSynced == true && services.sync.block == nil)) {
                ContentUnavailableView(emptyTitle, systemImage: emptySymbol)
            }
        }
        .navigationTitle(embedded ? "Mes tâches" : (project?.name ?? title))
        .toolbar {
            if context == .list {
                ToolbarItem(placement: .primaryAction) {
                    Button("Ajouter une tâche", systemImage: "plus") { creating = true }
                }
                if let project {
                    ToolbarItem(placement: .secondaryAction) {
                        Button("Modifier la liste", systemImage: "pencil") { editingList = project }
                    }
                }
            }
        }
        .sheet(isPresented: $creating) {
            TaskEditorView(mode: .create(projectId: projectId, schedule: nil))
        }
        .sheet(item: $editingList) { ProjectEditorView(project: $0) }
        .onChange(of: services.directory.projects) { previous, current in
            if let projectId, previous.contains(where: { $0.id == projectId }), !current.contains(where: { $0.id == projectId }) { dismiss() }
        }
        .task(id: ObservationKey(filter: filter, retryId: retryId)) { await observe() }
    }

    private var emptyTitle: String {
        switch filter {
        case .allActive: "Aucune tâche active."
        case .inbox: "Inbox vide."
        case .completed: "Aucune tâche terminée."
        case .trash: "Corbeille vide."
        default: "Aucune tâche."
        }
    }

    private var emptySymbol: String {
        switch filter {
        case .inbox: "tray"
        case .completed: "checkmark.circle"
        case .trash: "trash"
        default: "list.bullet"
        }
    }

    private func observe() async {
        loaded = false
        readFailed = false
        do {
            for try await rows in try services.tasks.observeTasks(filter) {
                try Task.checkCancellation()
                tasks = rows
                loaded = true
            }
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            readFailed = true
            loaded = true
        }
    }
}

/// À venir: the next 14 days grouped by date, computed occurrences included, then later.
struct UpcomingView: View {
    var embedded = false
    @Environment(AppServices.self) private var services
    @Environment(\.scenePhase) private var scenePhase
    @State private var today = CivilDate.today()

    var body: some View {
        let agenda = services.agenda.upcoming(today)
        List {
            if embedded { SyncNotice() }
            ForEach(agenda.days) { day in
                Section(DateText.heading(day.date)) {
                    ForEach(day.agenda.all) { item in
                        TaskRow(item: item, context: .day)
                    }
                }
            }
            if !agenda.later.isEmpty {
                Section("Plus tard") {
                    ForEach(agenda.later) { item in
                        TaskRow(item: item, context: .list)
                    }
                }
            }
        }
        .overlay {
            if services.agenda.readFailed {
                AgendaReadFailureView()
            } else if !services.agenda.loaded {
                ProgressView("Lecture des tâches…")
            } else if agenda.isEmpty && (!embedded || (services.sync.hasSynced == true && services.sync.block == nil)) {
                ContentUnavailableView("Rien de prévu ces prochains jours.", systemImage: "calendar")
            }
        }
        .navigationTitle(embedded ? "Mes tâches" : "À venir")
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { today = .today() }
        }
    }
}

/// Search results grouped as Actives, Terminées, Listes.
struct SearchResultsView: View {
    let query: String
    @Environment(AppServices.self) private var services
    @State private var tasks: [TaskItem] = []
    @State private var loaded = false
    @State private var failed = false
    @State private var retryId = UUID()

    private struct SearchKey: Hashable { let query: String; let retryId: UUID }

    var body: some View {
        let needle = SearchText.normalize([query])
        let lists = services.directory.projects.filter { SearchText.normalize([$0.name]).contains(needle) }
        let active = tasks.filter { !$0.isCompleted }
        let completed = tasks.filter(\.isCompleted)
        List {
            if !active.isEmpty {
                Section("Actives") {
                    ForEach(active) { TaskRow(task: $0, context: .list) }
                }
            }
            if !completed.isEmpty {
                Section("Terminées") {
                    ForEach(completed) { TaskRow(task: $0, context: .completed) }
                }
            }
            if !lists.isEmpty {
                Section("Listes") {
                    ForEach(lists) { project in
                        NavigationLink {
                            TaskListScreen(title: project.name, filter: .project(project.id), context: .list, projectId: project.id)
                        } label: {
                            Label(project.name, systemImage: "list.bullet")
                        }
                    }
                }
            }
        }
        .overlay {
            if failed {
                ContentUnavailableView {
                    Label("Recherche impossible", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("Les tâches n’ont pas pu être lues sur cet iPhone.")
                } actions: {
                    Button("Réessayer") { retryId = UUID() }
                }
            } else if !loaded {
                ProgressView("Recherche…")
            } else if active.isEmpty && completed.isEmpty && lists.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .task(id: SearchKey(query: query, retryId: retryId)) {
            loaded = false
            failed = false
            tasks = []
            // A short pause so that each keystroke does not start a new query.
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            do {
                for try await rows in try services.tasks.observeTasks(.search(query)) {
                    try Task.checkCancellation()
                    tasks = rows
                    loaded = true
                }
            } catch {
                if !Task.isCancelled { failed = true; tasks = [] }
            }
        }
    }
}
