import SwiftUI

/// Where a row is shown, to avoid repeating what the section already says.
enum TaskRowContext {
    case today
    case day
    case list
    case tag
    case completed
    case trash
}

/// TaskRow (02_Design/06_Components_Tokens.md): checkbox, title, time metadata, list and priority as text.
/// A row is a simple task or one occurrence of a series; a series shown in a list acts on its next occurrence.
/// VoiceOver reads one sentence and offers the actions; every swipe also exists in the menu and the sheets.
struct TaskRow: View {
    let item: AgendaItem
    var context: TaskRowContext = .list
    @Environment(AppServices.self) private var services
    @State private var sheet: RowSheet?
    @State private var errorMessage: String?
    @State private var subtasksExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(task: TaskItem, context: TaskRowContext = .list) {
        item = .simple(task)
        self.context = context
    }

    init(item: AgendaItem, context: TaskRowContext) {
        self.item = item
        self.context = context
    }

    private nonisolated enum RowSheet: Identifiable {
        case editor
        case occurrence(AgendaItem)
        case date(AgendaItem?)

        var id: String {
            switch self {
            case .editor: "editor"
            case .occurrence(let item): "occurrence:\(item.id)"
            case .date(let item): "date:\(item?.id ?? "")"
            }
        }
    }

    private var task: TaskItem { item.task }
    private var today: CivilDate { .today() }

    /// The occurrence the row acts on: its own, or for a series listed as a task, the next open one.
    private var occurrence: AgendaItem? {
        if item.isOccurrence { return item }
        guard task.isRecurring, !task.isCompleted, !task.isDeleted else { return nil }
        return SeriesCalculator.nextOccurrence(task: task, rows: services.agenda.rows(of: task.id), onOrAfter: today, zone: .current)
    }

    private var isMissedGroup: Bool {
        if case .missedGroup = item.kind { return true }
        return false
    }

    var body: some View {
        let occurrence = self.occurrence
        VStack(alignment: .leading, spacing: 0) {
            header(occurrence)
            if subtasksExpanded && !task.subtasks.isEmpty {
                TaskSubtaskList(subtasks: task.subtasks)
                    .padding(.leading, context == .trash ? 0 : TouchTarget.comfort + Spacing.md)
            }
        }
        .onChange(of: task.id) { subtasksExpanded = false }
        .onChange(of: task.subtasks.isEmpty) { _, empty in if empty { subtasksExpanded = false } }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if canCheck(occurrence) {
                Button(checkTitle, systemImage: task.isCompleted ? "arrow.uturn.backward" : "checkmark") { check(occurrence) }
                    .tint(.green)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if task.isDeleted {
                Button("Restaurer", systemImage: "arrow.uturn.backward", action: restore)
                    .tint(.blue)
            } else if let occurrence, item.isOccurrence {
                Button("Ignorer", systemImage: "forward") { skip(occurrence) }
                    .tint(.gray)
                if !isMissedGroup {
                    Button("Demain", systemImage: "calendar") { move(occurrence, to: today.adding(days: 1)) }
                        .tint(.orange)
                }
            } else {
                Button(task.isRecurring ? "Supprimer la série" : "Supprimer", systemImage: "trash", role: .destructive, action: delete)
                if canPlan {
                    Button("Demain", systemImage: "calendar") { plan(today.adding(days: 1)) }
                        .tint(.orange)
                }
            }
        }
        .contextMenu { menu(occurrence, withLists: true) }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .editor:
                TaskEditorView(mode: .edit(task))
            case .occurrence(let target):
                OccurrenceSheet(item: target)
            case .date(let target):
                DateChoiceSheet(initial: target?.schedule?.date ?? task.schedule?.date ?? today) { date in
                    if let target { move(target, to: date) } else { plan(date) }
                }
            }
        }
        .alert("Modification impossible", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func header(_ occurrence: AgendaItem?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
            if context != .trash {
                Button { check(occurrence) } label: {
                    Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(task.isCompleted ? Color.accentColor : Color.secondary)
                        .frame(minWidth: TouchTarget.comfort, minHeight: TouchTarget.comfort)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(!canCheck(occurrence))
                .accessibilityLabel("\(checkTitle) « \(task.title) »")
                .sensoryFeedback(.impact(weight: .light), trigger: task.isCompleted)
            }
            Button { open(occurrence) } label: {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(task.title)
                        .foregroundStyle(task.isCompleted || task.isDeleted ? Color.secondary : Color.primary)
                        .strikethrough(task.isCompleted)
                    if let details = details(occurrence) {
                        Group {
                            if task.isRecurring {
                                Text("\(Image(systemName: "repeat")) \(details)")
                            } else {
                                Text(details)
                            }
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, context == .trash ? Spacing.sm : 0)
                .frame(maxWidth: .infinity, minHeight: TouchTarget.comfort, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySentence(occurrence))
            .accessibilityAddTraits(.isButton)
            .accessibilityActions { menu(occurrence, withLists: false) }
            TaskTagLinks(taskId: task.id)
            if !task.subtasks.isEmpty {
                TaskSubtaskDisclosureButton(taskTitle: task.title, subtasks: task.subtasks, isExpanded: $subtasksExpanded)
            }
        }
    }

    // MARK: - Menu

    @ViewBuilder
    private func menu(_ occurrence: AgendaItem?, withLists: Bool) -> some View {
        if !task.subtasks.isEmpty {
            Button(subtasksExpanded ? "Masquer les sous-tâches" : "Afficher les sous-tâches", systemImage: subtasksExpanded ? "chevron.down" : "chevron.right") {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { subtasksExpanded.toggle() }
            }
        }
        if let occurrence, !task.isDeleted {
            if isMissedGroup {
                Button("Terminer la plus récente", systemImage: "checkmark") { complete(occurrence) }
                Button("Ignorer les précédentes", systemImage: "forward.end") { skipPrevious(occurrence) }
            } else {
                Button("Terminer", systemImage: "checkmark") { complete(occurrence) }
                Button("Ignorer cette fois", systemImage: "forward") { skip(occurrence) }
                Button("Aujourd’hui", systemImage: "sun.max") { move(occurrence, to: today) }
                Button("Demain", systemImage: "calendar") { move(occurrence, to: today.adding(days: 1)) }
                Button("Choisir une date…", systemImage: "calendar.badge.clock") { sheet = .date(occurrence) }
            }
            Button("Ouvrir l’occurrence", systemImage: "info.circle") { sheet = .occurrence(occurrence) }
            Button("Modifier la série", systemImage: "repeat") { sheet = .editor }
        } else {
            if canCheck(nil) {
                Button(task.isCompleted ? "Rouvrir" : "Marquer comme terminée", systemImage: task.isCompleted ? "arrow.uturn.backward" : "checkmark") { check(nil) }
            }
            if canPlan {
                Button("Aujourd’hui", systemImage: "sun.max") { plan(today) }
                Button("Demain", systemImage: "calendar") { plan(today.adding(days: 1)) }
                Button("Choisir une date…", systemImage: "calendar.badge.clock") { sheet = .date(nil) }
            }
            Button(task.isRecurring ? "Modifier la série" : "Modifier", systemImage: "pencil") { sheet = .editor }
        }
        if withLists && !task.isDeleted {
            Menu("Déplacer vers une liste", systemImage: "folder") {
                Button("Inbox") { moveToList(nil) }
                ForEach(services.directory.projects) { project in
                    Button(project.name) { moveToList(project.id) }
                }
            }
        }
        if task.isDeleted {
            Button("Restaurer", systemImage: "arrow.uturn.backward", action: restore)
        } else {
            Button(task.isRecurring ? "Supprimer la série" : "Supprimer", systemImage: "trash", role: .destructive, action: delete)
        }
    }

    // MARK: - Text

    private var checkTitle: String {
        task.isCompleted ? "Rouvrir" : "Terminer"
    }

    private var canPlan: Bool { !task.isDeleted && !task.isCompleted && !task.isRecurring }

    private func canCheck(_ occurrence: AgendaItem?) -> Bool {
        guard !task.isDeleted else { return false }
        if task.isRecurring {
            // An ended series is resumed from its row in Terminées; a running one completes an occurrence.
            return task.isCompleted || occurrence != nil
        }
        return true
    }

    private func details(_ occurrence: AgendaItem?) -> String? {
        var parts: [String] = []
        if context != .trash {
            if case .missedGroup(let count) = item.kind {
                parts.append(count == 1 ? "occurrence manquée" : "\(count) occurrences manquées")
                if let date = item.schedule?.local().date { parts.append("dernière " + DateText.day(date, today: today)) }
            } else if let schedule = item.isOccurrence ? item.schedule : (occurrence?.schedule ?? task.schedule) {
                // In a day's sections the day goes without saying, except for a task only due that day.
                let sameDay = (context == .today || context == .day) && item.kind != .deadline
                if sameDay, context == .day, let minutes = task.durationMinutes, let block = Self.block(schedule, minutes: minutes) {
                    parts.append(block)
                } else {
                    let text = DateText.moment(schedule, today: today, showDay: !sameDay)
                    if !text.isEmpty { parts.append(text) }
                    if let minutes = task.durationMinutes, schedule.time != nil { parts.append(DurationText.format(minutes)) }
                }
            }
            if let deadline = task.deadline, !task.isRecurring {
                parts.append("échéance " + DateText.moment(deadline, today: today))
            }
            if item.isMoved, let origin = item.originDate {
                parts.append("déplacée, prévue à l’origine " + DateText.day(origin, today: today))
            }
            if let recurrence = task.recurrence, context == .list || context == .tag || context == .completed {
                parts.append(recurrence.summary.lowercased())
            }
            if task.isRecurring && task.isCompleted { parts.append("série arrêtée") }
        }
        if context != .list, let list = services.directory.name(of: task.projectId) { parts.append(list) }
        if task.priority != .unset { parts.append("priorité " + task.priority.label.lowercased()) }
        if context == .completed, let completedAt = task.completedAt {
            parts.append((task.isRecurring ? "arrêtée " : "terminée ") + DateText.day(CivilDate(completedAt), today: today))
        }
        if context == .trash, let deletedAt = task.deletedAt {
            parts.append("supprimée " + DateText.day(CivilDate(deletedAt), today: today))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "17:00–18:00 (1 h)": a timed task with a known duration is a block in the day agenda.
    private static func block(_ schedule: TimeValue, minutes: Int) -> String? {
        guard let start = schedule.instant, let time = schedule.local().time else { return nil }
        let end = LocalTime(start.addingTimeInterval(TimeInterval(minutes * 60)))
        return "\(time)–\(end) (\(DurationText.format(minutes)))"
    }

    private func accessibilitySentence(_ occurrence: AgendaItem?) -> String {
        var sentence = task.title
        if !task.subtasks.isEmpty {
            sentence += ", \(task.subtasks.filter(\.isCompleted).count) sous-tâches terminées sur \(task.subtasks.count), " + (subtasksExpanded ? "sous-tâches affichées" : "sous-tâches masquées")
        }
        if task.isRecurring { sentence += ", tâche répétée" }
        if let details = details(occurrence) { sentence += ", " + details }
        if task.isDeleted {
            sentence += ", dans la corbeille"
        } else if !task.isRecurring {
            sentence += task.isCompleted ? ", terminée" : ", non terminée"
        }
        return sentence
    }

    // MARK: - Actions

    private func open(_ occurrence: AgendaItem?) {
        if item.isOccurrence, let occurrence {
            sheet = .occurrence(occurrence)
        } else {
            sheet = .editor
        }
    }

    private func check(_ occurrence: AgendaItem?) {
        if task.isRecurring && !task.isCompleted {
            if let occurrence { complete(occurrence) }
            return
        }
        let task = self.task
        let services = self.services
        Task {
            do {
                try await services.tasks.setCompleted(task.id, !task.isCompleted)
                if !task.isCompleted {
                    announce("« \(task.title) » terminée.", services: services) {
                        try? await services.tasks.setCompleted(task.id, false)
                    }
                } else if task.isRecurring {
                    AccessibilityNotification.Announcement("Série « \(task.title) » reprise.").post()
                }
            } catch {
                services.undo.offer("Impossible d’enregistrer sur cet iPhone.") {}
            }
        }
    }

    private func complete(_ occurrence: AgendaItem) {
        close(occurrence, skip: false, message: "« \(task.title) » terminée pour cette fois.")
    }

    private func skip(_ occurrence: AgendaItem) {
        close(occurrence, skip: true, message: "« \(task.title) » ignorée cette fois.")
    }

    private func close(_ occurrence: AgendaItem, skip: Bool, message: String) {
        guard let key = occurrence.occurrenceKey else { return }
        let task = occurrence.task
        let services = self.services
        Task {
            do {
                try await services.tasks.closeOccurrence(task, key: key, skip: skip)
                announce(message, services: services) {
                    try? await services.tasks.reopenOccurrence(task, key: key)
                }
            } catch {
                services.undo.offer("Impossible d’enregistrer sur cet iPhone.") {}
            }
        }
    }

    private func skipPrevious(_ occurrence: AgendaItem) {
        guard let key = occurrence.occurrenceKey else { return }
        let task = occurrence.task
        let services = self.services
        Task {
            do {
                try await services.tasks.skipMissed(before: key, of: task)
                AccessibilityNotification.Announcement("Occurrences précédentes ignorées.").post()
            } catch {
                services.undo.offer("Impossible d’enregistrer sur cet iPhone.") {}
            }
        }
    }

    /// Moves one occurrence to a day, keeping its time; back to its own day, the move is cancelled.
    private func move(_ occurrence: AgendaItem, to date: CivilDate) {
        guard let key = occurrence.occurrenceKey else { return }
        let task = occurrence.task
        let services = self.services
        let current = occurrence.schedule
        let target = TimeValue(date: date, time: current?.time, timeZone: current?.timeZone)
        let natural = SeriesCalculator.naturalSchedule(task: task, key: key)
        let value: TimeValue? = target == natural ? nil : target
        Task {
            do {
                try await services.tasks.rescheduleOccurrence(task, key: key, to: value)
            } catch {
                services.undo.offer("Impossible d’enregistrer sur cet iPhone.") {}
            }
        }
    }

    private func delete() {
        let task = self.task
        let services = self.services
        Task {
            do {
                try await services.tasks.setDeleted(task.id, true)
                announce("« \(task.title) » mise à la corbeille.", services: services) {
                    try? await services.tasks.setDeleted(task.id, false)
                }
            } catch {
                services.undo.offer("Impossible d’enregistrer sur cet iPhone.") {}
            }
        }
    }

    private func restore() {
        let task = self.task
        let services = self.services
        Task {
            do { try await services.tasks.setDeleted(task.id, false) }
            catch { errorMessage = (error as? ProjectMutationError)?.errorDescription ?? "Impossible de restaurer sur cet iPhone. Réessayez." }
        }
    }

    private func plan(_ date: CivilDate) {
        let task = self.task
        let services = self.services
        Task {
            do { try await services.tasks.reschedule(task, to: date) }
            catch { errorMessage = "Impossible de replanifier sur cet iPhone. Réessayez." }
        }
    }

    private func moveToList(_ projectId: String?) {
        let task = self.task
        let services = self.services
        guard task.projectId != projectId else { return }
        let base = TaskDraft(task: task)
        var draft = base
        draft.projectId = projectId
        Task {
            do {
                try await services.tasks.update(task.id, from: base, to: draft)
                let name = services.directory.name(of: projectId) ?? "Inbox"
                AccessibilityNotification.Announcement("« \(task.title) » déplacée vers \(name).").post()
            } catch {
                services.undo.offer("Impossible d’enregistrer sur cet iPhone.") {}
            }
        }
    }

    private func announce(_ message: String, services: AppServices, undo: @escaping @MainActor () async -> Void) {
        services.undo.offer(message, undo: undo)
        AccessibilityNotification.Announcement(message).post()
    }
}

/// "Choisir une date…": one day, the time and the zone are kept.
struct DateChoiceSheet: View {
    let initial: CivilDate
    let onChoose: (CivilDate) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()

    var body: some View {
        NavigationStack {
            ScrollView {
                DatePicker("Jour", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .padding(.horizontal, Spacing.lg)
            }
            .navigationTitle("Choisir une date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Choisir") {
                        onChoose(CivilDate(date))
                        dismiss()
                    }
                }
            }
            .onAppear { date = initial.noon() }
        }
        .presentationDetents([.medium, .large])
    }
}
