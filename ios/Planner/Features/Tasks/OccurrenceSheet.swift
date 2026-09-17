import SwiftUI

/// One occurrence of a series (02_Design/05_Calendar_Task_UX.md § Occurrence): its date, its origin when it was
/// moved, and the actions that only touch it. "Modifier la série" opens the editor of the whole series.
struct OccurrenceSheet: View {
    let item: AgendaItem
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var moveValue: TimeValue?
    @State private var editingSeries = false
    @State private var working = false
    @State private var errorMessage: String?

    private var task: TaskItem { item.task }
    private var key: String { item.occurrenceKey ?? "" }
    private var today: CivilDate { .today() }

    private var row: OccurrenceRow? {
        services.agenda.rows(of: task.id).first { $0.key == key }
    }

    private var status: OccurrenceStatus { row?.status ?? .open }

    /// The effective value, following local changes while the sheet is open.
    private var schedule: TimeValue? {
        row?.override ?? SeriesCalculator.naturalSchedule(task: task, key: key)
    }

    private var isMoved: Bool { row?.override != nil }

    private var missedCount: Int {
        if case .missedGroup(let count) = item.kind { return count }
        return 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(task.title)
                        .font(.headline)
                    if let schedule {
                        LabeledContent("Prévue", value: DateText.moment(schedule, today: today).capitalizedFirst)
                    }
                    if isMoved, let origin = OccurrenceKey.date(of: key) {
                        LabeledContent("Date d’origine", value: DateText.day(origin, today: today).capitalizedFirst)
                    }
                    if let recurrence = task.recurrence {
                        LabeledContent("Répétition", value: recurrence.summary)
                    }
                    if missedCount > 1 {
                        Text("\(missedCount) occurrences manquées ; voici la plus récente.")
                            .foregroundStyle(.secondary)
                    }
                    if status != .open {
                        Label(status == .completed ? "Terminée" : "Ignorée", systemImage: status == .completed ? "checkmark.circle" : "forward")
                    }
                    if task.isCompleted {
                        Label("Série arrêtée", systemImage: "stop.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                if task.isDeleted {
                    Section {
                        Label("Cette série est dans la corbeille.", systemImage: "trash")
                    }
                } else if !task.isCompleted {
                    actions
                }
                Section {
                    Button("Modifier la série", systemImage: "repeat") { editingSeries = true }
                } footer: {
                    Text("Le titre, l’heure et la règle changent pour toutes les occurrences.")
                }
            }
            .disabled(working)
            .navigationTitle("Occurrence")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
            .sheet(isPresented: $editingSeries) {
                TaskEditorView(mode: .edit(task))
            }
            .alert("Enregistrement impossible", isPresented: hasError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear {
                if moveValue == nil { moveValue = schedule }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if status == .open {
            Section {
                Button("Terminer", systemImage: "checkmark") { close(skip: false) }
                Button("Ignorer cette fois", systemImage: "forward") { close(skip: true) }
                if missedCount > 1 {
                    Button("Ignorer les précédentes", systemImage: "forward.end", action: skipPrevious)
                }
            }
            Section {
                TimeValueFields(value: $moveValue, allowsNone: false)
                Button("Déplacer", action: move)
                    .disabled(moveValue == nil || moveValue == schedule)
                if isMoved {
                    Button("Annuler le déplacement", role: .destructive) { reschedule(nil) }
                }
            } header: {
                Text("Déplacer cette occurrence")
            } footer: {
                Text("Les autres occurrences ne changent pas.")
            }
        } else {
            Section {
                Button("Rouvrir", systemImage: "arrow.uturn.backward", action: reopen)
            }
        }
    }

    private var hasError: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func close(skip: Bool) {
        let task = self.task
        let key = self.key
        let services = self.services
        run {
            try await services.tasks.closeOccurrence(task, key: key, skip: skip)
            let message = skip ? "« \(task.title) » ignorée cette fois." : "« \(task.title) » terminée pour cette fois."
            services.undo.offer(message) {
                try? await services.tasks.reopenOccurrence(task, key: key)
            }
            AccessibilityNotification.Announcement(message).post()
            dismiss()
        }
    }

    private func skipPrevious() {
        let task = self.task
        let key = self.key
        let services = self.services
        run {
            try await services.tasks.skipMissed(before: key, of: task)
            AccessibilityNotification.Announcement("Occurrences précédentes ignorées.").post()
        }
    }

    private func reopen() {
        let task = self.task
        let key = self.key
        let services = self.services
        run { try await services.tasks.reopenOccurrence(task, key: key) }
    }

    /// Moving back to the occurrence's own value cancels the move.
    private func move() {
        guard let moveValue else { return }
        reschedule(moveValue == SeriesCalculator.naturalSchedule(task: task, key: key) ? nil : moveValue)
    }

    private func reschedule(_ value: TimeValue?) {
        let task = self.task
        let key = self.key
        let services = self.services
        run {
            try await services.tasks.rescheduleOccurrence(task, key: key, to: value)
            moveValue = value ?? SeriesCalculator.naturalSchedule(task: task, key: key)
            AccessibilityNotification.Announcement(value == nil ? "Déplacement annulé." : "Occurrence déplacée.").post()
        }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        working = true
        Task {
            defer { working = false }
            do {
                try await work()
            } catch {
                errorMessage = "La modification n’a pas pu être enregistrée sur cet iPhone."
            }
        }
    }
}

/// What a notification points to, opened once the task is read from this iPhone.
struct OpenTargetView: View {
    let target: OpenTarget
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var task: TaskItem?
    @State private var loaded = false

    var body: some View {
        Group {
            if let task {
                if task.isRecurring, let key = target.occurrenceKey,
                   let item = SeriesCalculator.occurrence(task: task, rows: services.agenda.rows(of: task.id), key: key) {
                    OccurrenceSheet(item: item)
                } else {
                    TaskEditorView(mode: .edit(task))
                }
            } else if loaded {
                NavigationStack {
                    ContentUnavailableView("Tâche introuvable", systemImage: "questionmark.circle",
                                           description: Text("Elle a peut-être été supprimée."))
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("OK") { dismiss() }
                            }
                        }
                }
            } else {
                ProgressView()
            }
        }
        .task(id: target) {
            task = try? await services.tasks.task(id: target.taskId)
            loaded = true
        }
    }
}
