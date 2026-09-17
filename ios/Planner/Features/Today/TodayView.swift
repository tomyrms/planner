import SwiftUI

/// Today (02_Design/05_Calendar_Task_UX.md): commitments, to do, deadlines, then what to replan.
/// Series appear through their occurrences of the day and their missed occurrences.
struct TodayView: View {
    var embedded = false
    @Environment(AppServices.self) private var services
    @Environment(\.scenePhase) private var scenePhase
    @State private var today = CivilDate.today()
    @State private var creating = false
    @State private var showReplan = true
    @State private var showOverdue = true

    var body: some View {
        if embedded {
            VStack(spacing: 0) {
                Text(DateText.heading(today))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Spacing.lg)
                    .padding(.bottom, Spacing.xs)
                    .accessibilityAddTraits(.isHeader)
                content
            }
        } else {
            NavigationStack { content }
        }
    }

    private var content: some View {
        let agenda = services.agenda.today(today)
        return List {
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
            if services.agenda.readFailed {
                AgendaReadFailureView()
            } else if !services.agenda.loaded {
                ProgressView("Lecture des tâches…")
            } else if agenda.isEmpty && (!embedded || (services.sync.hasSynced == true && services.sync.block == nil)) {
                ContentUnavailableView {
                    Label("Rien de prévu aujourd’hui.", systemImage: "sun.max")
                } actions: {
                    Button("Ajouter une tâche") { creating = true }
                }
            }
        }
        .navigationTitle(embedded ? "Mes tâches" : DateText.heading(today))
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

/// Shared read failure for the agenda projections; retry restarts only the local observers.
struct AgendaReadFailureView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        ContentUnavailableView {
            Label("Lecture impossible", systemImage: "exclamationmark.triangle")
        } description: {
            Text("Les tâches n’ont pas pu être lues sur cet iPhone.")
        } actions: {
            Button("Réessayer") { services.agenda.start(services.tasks) }
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
