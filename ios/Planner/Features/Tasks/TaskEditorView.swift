import SwiftUI

/// Native sheet working on a draft: nothing is written before "Enregistrer", a remote change never
/// overwrites what is being typed (03_iOS/01_SwiftUI_Architecture.md, 02_Design/05_Calendar_Task_UX.md).
/// A series is edited as a whole here; one occurrence is changed from its own sheet.
struct TaskEditorView: View {
    enum Mode {
        case create(projectId: String?, schedule: TimeValue?)
        case edit(TaskItem)
        case retryCreate(TaskDraft)
        case retryPatch(TaskItem, base: TaskDraft, draft: TaskDraft, fields: Set<String>)
    }

    let mode: Mode
    var onSaved: (() -> Void)? = nil
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var draft = TaskDraft()
    @State private var base = TaskDraft()
    @State private var prepared = false
    @State private var current: TaskItem?
    @State private var currentTagIds: Set<String> = []
    @State private var tagsLoaded = false
    @State private var tagsReadFailed = false
    @State private var tagsRetryId = UUID()
    @State private var confirmingDiscard = false
    @State private var confirmingConflict = false
    @State private var confirmingEnd = false
    @State private var saving = false
    @State private var errorMessage: String?
    @FocusState private var titleFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                if isCorrection {
                    Section {
                        Text(isCreating
                             ? "Vérifiez ces valeurs. Ajouter créera une nouvelle tâche, indépendante de la demande refusée."
                             : "Vérifiez les valeurs refusées avant d’enregistrer une nouvelle correction. Les autres champs partent de la version présente sur cet iPhone.")
                        Text("Le rejet initial reste conservé dans Réglages.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    TextField("Titre", text: $draft.title, axis: .vertical)
                        .focused($titleFocused)
                    TextField("Description", text: $draft.notes, axis: .vertical)
                        .lineLimit(2...8)
                }
                TaskSubtasksSection(subtasks: $draft.subtasks, isRecurring: isSeries)
                Section {
                    if tagsReadFailed {
                        Text("Les tags de cette tâche n’ont pas pu être lus.").foregroundStyle(.secondary)
                        Button("Réessayer") { tagsRetryId = UUID() }
                    } else if !tagsLoaded {
                        ProgressView("Lecture des tags…")
                    } else {
                        NavigationLink {
                            TagPickerView(selection: $draft.tagIds)
                        } label: {
                            HStack(spacing: Spacing.md) {
                                Text("Tags")
                                Spacer(minLength: Spacing.sm)
                                let names = services.tagDirectory.snapshot.catalogue
                                    .filter { draft.tagIds.contains($0.id) }.map { $0.tag.name }
                                if names.isEmpty {
                                    Text(draft.tagIds.isEmpty ? "Aucun" : "\(draft.tagIds.count) sélectionnés")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                } else {
                                    TaskTagSummaryLabel(names: names)
                                }
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Modifier les tags, \(draft.tagIds.count) sélectionnés")
                        }
                    }
                }
                if changedElsewhere {
                    Section {
                        Label(currentIsDeleted ? "Cette tâche a été supprimée ailleurs." : "Cette tâche a changé ailleurs pendant l’édition.",
                              systemImage: "exclamationmark.triangle")
                    }
                }
                TimeValueSection(
                    title: isSeries ? "Première occurrence" : "Prévu",
                    value: $draft.schedule,
                    allowsNone: !isSeries,
                    footer: isSeries ? "L’heure s’applique à toutes les occurrences." : nil
                )
                if draft.schedule?.time != nil {
                    TaskDurationSection(minutes: $draft.durationMinutes)
                }
                if !isSeries {
                    TimeValueSection(title: "Échéance", value: $draft.deadline)
                }
                ReminderSection(
                    reminder: $draft.reminder,
                    schedule: draft.schedule,
                    deadline: isSeries ? nil : draft.deadline,
                    allowsAbsolute: !isSeries,
                    savedId: draft.reminder == base.reminder ? base.reminderId : nil,
                    isNew: draft.reminder != base.reminder
                )
                if canChooseRecurrence {
                    RecurrenceSection(recurrence: recurrenceBinding, anchor: draft.schedule?.date ?? .today(), allowsNone: isCreating)
                        .disabled(!draft.subtasks.isEmpty)
                    if !draft.subtasks.isEmpty {
                        Section {
                            Text("Retirez les sous-tâches avant de choisir une répétition.").foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Section {
                        LabeledContent("Répétition", value: "Aucune")
                    } header: {
                        Text("Répétition")
                    } footer: {
                        Text("Une tâche existante ne devient pas répétée : créez une nouvelle tâche avec une répétition.")
                    }
                }
                Section {
                    Picker("Liste", selection: $draft.projectId) {
                        Text("Inbox").tag(String?.none)
                        if let id = draft.projectId, !services.directory.projects.contains(where: { $0.id == id }) {
                            Text("Liste indisponible sur cet iPhone").tag(String?.some(id))
                        }
                        ForEach(services.directory.projects) { project in
                            Text(project.name).tag(String?.some(project.id))
                        }
                    }
                    if requiresAvailableProject {
                        Text("Choisissez Inbox ou une liste disponible avant d’enregistrer la correction.")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    Picker("Priorité", selection: $draft.priority) {
                        ForEach(Priority.allCases) { priority in
                            Text(priority.label).tag(priority)
                        }
                    }
                }
                if let task = editedTask {
                    AssistantChangesSection(taskId: task.id)
                    Section {
                        if task.isRecurring && !task.isDeleted {
                            if liveTask?.isCompleted ?? false {
                                Button("Reprendre la série") { setSeriesRunning(true) }
                            } else {
                                Button("Arrêter la série") { confirmingEnd = true }
                            }
                        }
                        if task.isDeleted {
                            Button("Restaurer") { setDeleted(task, false) }
                        } else {
                            Button(task.isRecurring ? "Supprimer la série" : "Supprimer", role: .destructive) { setDeleted(task, true) }
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") {
                        if hasChanges { confirmingDiscard = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isCreating ? "Ajouter" : "Enregistrer", action: save)
                        .disabled(!canSave)
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
            .confirmationDialog("Arrêter la série ?", isPresented: $confirmingEnd, titleVisibility: .visible) {
                Button("Arrêter la série", role: .destructive) { setSeriesRunning(false) }
                Button("Continuer", role: .cancel) {}
            } message: {
                Text("Plus aucune occurrence ne sera proposée. La série reste dans Terminées et peut reprendre.")
            }
            .alert("Enregistrement impossible", isPresented: hasError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear(perform: prepare)
            .task(id: editedTaskId) { await observeCurrent() }
            .task(id: tagsRetryId) { await observeTagIds() }
        }
    }

    private var title: String {
        if isCreating { return "Nouvelle tâche" }
        return isSeries ? "Tâche répétée" : "Tâche"
    }

    private var isCreating: Bool {
        switch mode {
        case .create, .retryCreate: true
        case .edit, .retryPatch: false
        }
    }

    private var editedTask: TaskItem? {
        switch mode {
        case .edit(let task), .retryPatch(let task, _, _, _): task
        case .create, .retryCreate: nil
        }
    }

    private var isCorrection: Bool {
        switch mode {
        case .retryCreate, .retryPatch: true
        case .create, .edit: false
        }
    }

    private var reapplyingFields: Set<String> {
        if case .retryPatch(_, _, _, let fields) = mode { return fields }
        return []
    }

    private var editedTaskId: String? { editedTask?.id }

    /// The stored task as it is now (for "Arrêter" / "Reprendre").
    private var liveTask: TaskItem? { current ?? editedTask }

    private var isSeries: Bool { draft.recurrence != nil }

    /// The command catalogue only creates series: a simple task keeps no recurrence after creation.
    private var canChooseRecurrence: Bool {
        isCreating || (editedTask?.isRecurring ?? false)
    }

    /// Choosing a repetition gives the task a planned date and removes its deadline (a series has none in V1).
    private var recurrenceBinding: Binding<RecurrenceRule?> {
        Binding(
            get: { draft.recurrence },
            set: { rule in
                draft.recurrence = rule
                if rule != nil {
                    if draft.schedule == nil { draft.schedule = TimeValue(date: .today()) }
                    draft.deadline = nil
                    if let reminder = draft.reminder, reminder.usesDeadline || isAbsolute(reminder) { draft.reminder = nil }
                }
            }
        )
    }

    private func isAbsolute(_ rule: ReminderRule) -> Bool {
        if case .absolute = rule { return true }
        return false
    }

    private var hasChanges: Bool { draft != base }

    /// A new or changed reminder must have its base now, or the server refuses it (REMINDER_BASE_MISSING).
    private var reminderIsValid: Bool {
        guard let reminder = draft.reminder, draft.reminder != base.reminder else { return true }
        return ReminderMath.trigger(reminder, schedule: draft.schedule, deadline: isSeries ? nil : draft.deadline, deviceZone: .current) != .baseMissing
    }

    private var canSave: Bool {
        draft.isValid && draft.isValidSeries && reminderIsValid && tagsLoaded && !tagsReadFailed
            && !requiresAvailableProject && !saving && (isCreating || hasChanges || !reapplyingFields.isEmpty)
    }

    private var requiresAvailableProject: Bool {
        guard isCorrection, isCreating || reapplyingFields.contains("projectId"), let id = draft.projectId else { return false }
        return !services.directory.projects.contains(where: { $0.id == id })
    }

    /// The stored task no longer matches what the draft started from (change or deletion elsewhere).
    private var changedElsewhere: Bool {
        guard let current else { return false }
        return current.isDeleted != currentWasDeleted || storedDraft(current) != base
    }

    private func storedDraft(_ task: TaskItem) -> TaskDraft {
        TaskDraft(task: task, reminder: services.agenda.reminder(of: task.id), tagIds: currentTagIds)
    }

    private var currentIsDeleted: Bool { current?.isDeleted ?? false }

    private var currentWasDeleted: Bool { editedTask?.isDeleted ?? false }

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
            base = storedDraft(task)
            draft = base
        case .retryCreate(let proposed):
            draft = proposed
            base = TaskDraft()
            titleFocused = true
        case .retryPatch(_, let original, let proposed, _):
            base = original
            draft = proposed
        }
    }

    private func observeCurrent() async {
        guard let id = editedTaskId else { return }
        do {
            for try await rows in try services.tasks.observeTask(id: id) {
                try Task.checkCancellation()
                current = rows.first
            }
        } catch {}
    }

    private func observeTagIds() async {
        prepare()
        guard let id = editedTaskId else { tagsLoaded = true; return }
        tagsReadFailed = false
        do {
            for try await ids in try services.tasks.observeTagIds(taskId: id) {
                try Task.checkCancellation()
                currentTagIds = Set(ids)
                if !tagsLoaded {
                    base.tagIds = currentTagIds
                    draft.tagIds = currentTagIds
                    tagsLoaded = true
                }
            }
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            tagsReadFailed = true
        }
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
        let services = self.services
        let stored = current
        let fields = reapplyingFields
        saving = true
        Task {
            defer { saving = false }
            do {
                switch mode {
                case .create, .retryCreate:
                    try await services.tasks.create(draft)
                case .edit(let task), .retryPatch(let task, _, _, _):
                    guard !(stored ?? task).isDeleted else {
                        errorMessage = "Cette tâche est supprimée. Restaurez-la explicitement depuis la Corbeille avant de la modifier."
                        return
                    }
                    if task.isRecurring {
                        // The revision read now is the precondition when nothing else is queued for the series.
                        try await services.tasks.updateSeries(stored ?? task, from: base, to: draft, reapplying: fields)
                    } else {
                        try await services.tasks.update(task.id, from: base, to: draft, reapplying: fields)
                    }
                }
                onSaved?()
                // Asked at the first reminder, never at launch (03_iOS/03_Notifications_EventKit_Widgets.md §1.9).
                if draft.reminder != nil {
                    await services.reminders.requestAuthorizationIfNeeded()
                }
                dismiss()
            } catch {
                errorMessage = (error as? TaskDetailsError)?.errorDescription ?? (error as? ProjectMutationError)?.errorDescription ?? "La modification n’a pas pu être enregistrée sur cet iPhone."
            }
        }
    }

    private func showCurrent() {
        guard let current else { return }
        base = storedDraft(current)
        draft = base
    }

    private func setSeriesRunning(_ running: Bool) {
        guard let task = liveTask else { return }
        let services = self.services
        Task {
            do {
                if running {
                    try await services.tasks.setCompleted(task.id, false)
                } else {
                    try await services.tasks.endSeries(task)
                    services.undo.offer("Série « \(task.title) » arrêtée.") {
                        try? await services.tasks.setCompleted(task.id, false)
                    }
                }
                dismiss()
            } catch {
                errorMessage = "La modification n’a pas pu être enregistrée sur cet iPhone."
            }
        }
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
    var allowsNone = true
    var footer: String?

    var body: some View {
        Section {
            TimeValueFields(value: $value, allowsNone: allowsNone)
        } header: {
            Text(title)
        } footer: {
            if let footer { Text(footer) }
        }
    }
}

struct TimeValueFields: View {
    @Binding var value: TimeValue?
    var allowsNone = true

    var body: some View {
        if allowsNone {
            Toggle("Date", isOn: hasDate)
        }
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
                return LocalTime.date(clock, on: current.date)
            },
            set: { date in
                guard let current = value else { return }
                value = TimeValue(date: current.date, time: LocalTime(date), timeZone: TimeZone.current.identifier)
            }
        )
    }
}

nonisolated extension LocalTime {
    /// A `Date` for pickers: this wall-clock time on that day, on this iPhone.
    static func date(_ time: LocalTime, on day: CivilDate) -> Date {
        Calendar.planner(in: .current).date(from: DateComponents(
            year: day.year, month: day.month, day: day.day, hour: time.hour, minute: time.minute)) ?? Date()
    }
}
