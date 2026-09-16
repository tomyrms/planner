import SwiftUI

/// Today (02_Design/05_Calendar_Task_UX.md): commitments, to do, deadlines, then what to replan.
struct TodayView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.scenePhase) private var scenePhase
    @State private var tasks: [TaskItem] = []
    @State private var today = CivilDate.today()
    @State private var creating = false
    @State private var showReplan = true
    @State private var showOverdue = true

    var body: some View {
        let agenda = TodayAgenda(tasks: tasks, today: today)
        NavigationStack {
            List {
                SyncNotice()
                if let summary = agenda.summary {
                    Section {
                        Text(summary)
                            .foregroundStyle(.secondary)
                    }
                }
                rows("Engagements", agenda.commitments)
                rows("À faire aujourd’hui", agenda.todo)
                rows("Échéances", agenda.deadlines)
                collapsible("À replanifier", agenda.toReplan, isExpanded: $showReplan)
                collapsible("Échéance dépassée", agenda.overdue, isExpanded: $showOverdue)
            }
            .overlay {
                if agenda.isEmpty {
                    ContentUnavailableView {
                        Label("Rien de prévu aujourd’hui.", systemImage: "sun.max")
                    } actions: {
                        Button("Ajouter une tâche") { creating = true }
                    }
                }
            }
            .navigationTitle(DateText.heading(today))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Ajouter une tâche", systemImage: "plus") { creating = true }
                }
            }
            .sheet(isPresented: $creating) {
                TaskEditorView(mode: .create(projectId: nil, schedule: TimeValue(date: today)))
            }
            .task { await observe() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { today = .today() }
            }
        }
    }

    @ViewBuilder
    private func rows(_ title: String, _ items: [TaskItem]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { task in
                    TaskRow(task: task, context: .today)
                }
            }
        }
    }

    @ViewBuilder
    private func collapsible(_ title: String, _ items: [TaskItem], isExpanded: Binding<Bool>) -> some View {
        if !items.isEmpty {
            Section {
                DisclosureGroup(isExpanded: isExpanded) {
                    ForEach(items) { task in
                        TaskRow(task: task, context: .list)
                    }
                } label: {
                    Text("\(title) (\(items.count))")
                        .font(.headline)
                }
            }
        }
    }

    private func observe() async {
        do {
            for try await rows in try services.tasks.observeTasks(.dated) {
                tasks = rows
            }
        } catch {}
    }
}

/// First sync or a blocked sync, shown only when it matters (no badge when all is well).
struct SyncNotice: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        if services.sync.block != nil {
            Section {
                Label("La synchronisation attend une action : Listes › Réglages.", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
            }
        } else if services.sync.status.hasSynced != true {
            Section {
                Label("Première synchronisation…", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
