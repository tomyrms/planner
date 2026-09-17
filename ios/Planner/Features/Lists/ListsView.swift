import SwiftUI

/// Listes: Inbox, À venir, the user's lists, Terminées, Corbeille; search covers tasks and lists.
struct ListsView: View {
    @Environment(AppServices.self) private var services
    @State private var query = ""
    @State private var creatingTask = false
    @State private var showingSettings = false
    @State private var namingList = false
    @State private var newListName = ""

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
            .alert("Nouvelle liste", isPresented: $namingList) {
                TextField("Nom", text: $newListName)
                Button("Créer", action: createList)
                Button("Annuler", role: .cancel) { newListName = "" }
            }
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

    private func createList() {
        let name = newListName.trimmingCharacters(in: .whitespacesAndNewlines)
        newListName = ""
        guard !name.isEmpty else { return }
        let tasks = services.tasks
        Task { _ = try? await tasks.createProject(name: String(name.prefix(200))) }
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
    @State private var tasks: [TaskItem] = []
    @State private var loaded = false
    @State private var creating = false
    @State private var readFailed = false
    @State private var retryId = UUID()

    private struct ObservationKey: Hashable {
        let filter: TaskFilter
        let retryId: UUID
    }

    var body: some View {
        List {
            if embedded { SyncNotice() }
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
            } else if tasks.isEmpty && (!embedded || (services.sync.hasSynced == true && services.sync.block == nil)) {
                ContentUnavailableView(emptyTitle, systemImage: emptySymbol)
            }
        }
        .navigationTitle(embedded ? "Mes tâches" : title)
        .toolbar {
            if context == .list {
                ToolbarItem(placement: .primaryAction) {
                    Button("Ajouter une tâche", systemImage: "plus") { creating = true }
                }
            }
        }
        .sheet(isPresented: $creating) {
            TaskEditorView(mode: .create(projectId: projectId, schedule: nil))
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
            if active.isEmpty && completed.isEmpty && lists.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .task(id: query) {
            // A short pause so that each keystroke does not start a new query.
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            do {
                for try await rows in try services.tasks.observeTasks(.search(query)) {
                    tasks = rows
                }
            } catch {}
        }
    }
}
