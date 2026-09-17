import SwiftUI

/// Native sheet working on a draft: nothing is written before "Enregistrer", a remote change never
/// overwrites what is being typed (03_iOS/01_SwiftUI_Architecture.md, 02_Design/05_Calendar_Task_UX.md).
struct TaskEditorView: View {
    enum Mode {
        case create(projectId: String?, schedule: TimeValue?)
        case edit(TaskItem)
    }

    let mode: Mode
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var draft = TaskDraft()
    @State private var base = TaskDraft()
    @State private var prepared = false
    @State private var current: TaskItem?
    @State private var confirmingDiscard = false
    @State private var confirmingConflict = false
    @State private var saving = false
    @State private var errorMessage: String?
    @FocusState private var titleFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Titre", text: $draft.title, axis: .vertical)
                        .focused($titleFocused)
                    TextField("Notes", text: $draft.notes, axis: .vertical)
                        .lineLimit(2...8)
                }
                if changedElsewhere {
                    Section {
                        Label(currentIsDeleted ? "Cette tâche a été supprimée ailleurs." : "Cette tâche a changé ailleurs pendant l’édition.",
                              systemImage: "exclamationmark.triangle")
                    }
                }
                if isRecurring {
                    Section {
                        Label("Tâche répétée : le prévu et l’échéance se modifieront avec la gestion des répétitions.", systemImage: "repeat")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    TimeValueSection(title: "Prévu", value: $draft.schedule)
                    if draft.schedule?.time != nil {
                        Section {
                            Picker("Durée", selection: $draft.durationMinutes) {
                                Text("Aucune").tag(Int?.none)
                                ForEach([15, 30, 45, 60, 90, 120, 180], id: \.self) { minutes in
                                    Text(DurationText.format(minutes)).tag(Int?.some(minutes))
                                }
                            }
                        }
                    }
                    TimeValueSection(title: "Échéance", value: $draft.deadline)
                }
                Section {
                    Picker("Liste", selection: $draft.projectId) {
                        Text("Inbox").tag(String?.none)
                        ForEach(services.directory.projects) { project in
                            Text(project.name).tag(String?.some(project.id))
                        }
                    }
                    Picker("Priorité", selection: $draft.priority) {
                        ForEach(Priority.allCases) { priority in
                            Text(priority.label).tag(priority)
                        }
                    }
                }
                if case .edit(let task) = mode {
                    AssistantChangesSection(taskId: task.id)
                    Section {
                        if task.isDeleted {
                            Button("Restaurer") { setDeleted(task, false) }
                        } else {
                            Button("Supprimer", role: .destructive) { setDeleted(task, true) }
                        }
                    }
                }
            }
            .navigationTitle(isCreating ? "Nouvelle tâche" : "Tâche")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") {
                        if hasChanges { confirmingDiscard = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isCreating ? "Ajouter" : "Enregistrer", action: save)
                        .disabled(!draft.isValid || saving || (!isCreating && !hasChanges))
                }
            }
            .interactiveDismissDisabled(hasChanges)
            .confirmationDialog("Abandonner les modifications ?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("Abandonner", role: .destructive) { dismiss() }
                Button("Continuer l’édition", role: .cancel) {}
            }
            .confirmationDialog("Cette tâche a changé", isPresented: $confirmingConflict, titleVisibility: .visible) {
                Button("Garder mes modifications", action: commit)
                Button("Voir la version actuelle", action: showCurrent)
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("Elle a été modifiée ailleurs pendant l’édition.")
            }
            .alert("Enregistrement impossible", isPresented: hasError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear(perform: prepare)
            .task(id: editedTaskId) { await observeCurrent() }
        }
    }

    private var isCreating: Bool {
        if case .create = mode { return true }
        return false
    }

    private var editedTaskId: String? {
        if case .edit(let task) = mode { return task.id }
        return nil
    }

    private var isRecurring: Bool {
        if case .edit(let task) = mode { return task.isRecurring }
        return false
    }

    private var hasChanges: Bool { draft != base }

    /// The stored task no longer matches what the draft started from (change or deletion elsewhere).
    private var changedElsewhere: Bool {
        guard let current else { return false }
        return current.isDeleted != currentWasDeleted || TaskDraft(task: current) != base
    }

    private var currentIsDeleted: Bool { current?.isDeleted ?? false }

    private var currentWasDeleted: Bool {
        if case .edit(let task) = mode { return task.isDeleted }
        return false
    }

    private var hasError: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        switch mode {
        case .create(let projectId, let schedule):
            draft.projectId = projectId
            draft.schedule = schedule
            base = draft
            titleFocused = true
        case .edit(let task):
            base = TaskDraft(task: task)
            draft = base
        }
    }

    private func observeCurrent() async {
        guard let id = editedTaskId else { return }
        do {
            for try await rows in try services.tasks.observeTask(id: id) {
                current = rows.first
            }
        } catch {}
    }

    private func save() {
        if changedElsewhere {
            confirmingConflict = true
        } else {
            commit()
        }
    }

    private func commit() {
        let draft = self.draft
        let base = self.base
        let mode = self.mode
        let tasks = services.tasks
        saving = true
        Task {
            defer { saving = false }
            do {
                switch mode {
                case .create:
                    try await tasks.create(draft)
                case .edit(let task):
                    try await tasks.update(task.id, from: base, to: draft)
                }
                dismiss()
            } catch {
                errorMessage = "La modification n’a pas pu être enregistrée sur cet iPhone."
            }
        }
    }

    private func showCurrent() {
        guard let current else { return }
        base = TaskDraft(task: current)
        draft = base
    }

    private func setDeleted(_ task: TaskItem, _ deleted: Bool) {
        let services = self.services
        Task {
            do {
                try await services.tasks.setDeleted(task.id, deleted)
                if deleted {
                    services.undo.offer("« \(task.title) » mise à la corbeille.") {
                        try? await services.tasks.setDeleted(task.id, false)
                    }
                }
                dismiss()
            } catch {
                errorMessage = "La modification n’a pas pu être enregistrée sur cet iPhone."
            }
        }
    }
}

/// "Aucune / date / date + heure" for Prévu and Échéance. A time uses this iPhone's zone.
struct TimeValueSection: View {
    let title: String
    @Binding var value: TimeValue?

    var body: some View {
        Section(title) {
            Toggle("Date", isOn: hasDate)
            if let current = value {
                DatePicker("Jour", selection: day, displayedComponents: .date)
                Toggle("Heure", isOn: hasTime)
                if current.time != nil {
                    DatePicker("Heure", selection: time, displayedComponents: .hourAndMinute)
                    if current.isInOtherZone, let zone = current.timeZone {
                        LabeledContent("Fuseau", value: zone)
                    }
                }
            }
        }
    }

    private var hasDate: Binding<Bool> {
        Binding(
            get: { value != nil },
            set: { enabled in value = enabled ? TimeValue(date: .today()) : nil }
        )
    }

    private var hasTime: Binding<Bool> {
        Binding(
            get: { value?.time != nil },
            set: { enabled in
                guard let current = value else { return }
                let nextHour = LocalTime(hour: min(23, LocalTime(Date()).hour + 1), minute: 0)
                value = TimeValue(date: current.date, time: enabled ? nextHour : nil, timeZone: nil)
            }
        )
    }

    private var day: Binding<Date> {
        Binding(
            get: { value?.date.noon() ?? Date() },
            set: { date in
                guard let current = value else { return }
                value = TimeValue(date: CivilDate(date), time: current.time, timeZone: current.timeZone)
            }
        )
    }

    /// Shown and edited as a wall-clock time on this iPhone; editing moves the value to this iPhone's zone.
    private var time: Binding<Date> {
        Binding(
            get: {
                guard let current = value, let clock = current.time else { return Date() }
                return Calendar.planner(in: .current).date(from: DateComponents(
                    year: current.date.year, month: current.date.month, day: current.date.day,
                    hour: clock.hour, minute: clock.minute)) ?? Date()
            },
            set: { date in
                guard let current = value else { return }
                value = TimeValue(date: current.date, time: LocalTime(date), timeZone: TimeZone.current.identifier)
            }
        )
    }
}
