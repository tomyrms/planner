import SwiftUI

/// Today (02_Design/05_Calendar_Task_UX.md): commitments, to do, deadlines, then what to replan.
/// Series appear through their occurrences of the day and their missed occurrences.
struct TodayView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.scenePhase) private var scenePhase
    @State private var today = CivilDate.today()
    @State private var creating = false
    @State private var showReplan = true
    @State private var showOverdue = true

    var body: some View {
        let agenda = services.agenda.today(today)
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
                if services.agenda.loaded && agenda.isEmpty {
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
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { today = .today() }
            }
        }
    }

    @ViewBuilder
    private func rows(_ title: String, _ items: [AgendaItem]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { item in
                    TaskRow(item: item, context: .today)
                }
            }
        }
    }

    /// Late items show their day: they are listed with the list context.
    @ViewBuilder
    private func collapsible(_ title: String, _ items: [AgendaItem], isExpanded: Binding<Bool>) -> some View {
        if !items.isEmpty {
            Section {
                DisclosureGroup(isExpanded: isExpanded) {
                    ForEach(items) { item in
                        TaskRow(item: item, context: .list)
                    }
                } label: {
                    Text("\(title) (\(items.count))")
                        .font(.headline)
                }
            }
        }
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
        } else if services.sync.hasSynced != true {
            Section {
                Label("Première synchronisation…", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
