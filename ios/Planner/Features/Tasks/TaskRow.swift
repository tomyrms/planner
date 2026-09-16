import SwiftUI

/// Where a row is shown, to avoid repeating what the section already says.
enum TaskRowContext {
    case today
    case day
    case list
    case completed
    case trash
}

/// TaskRow (02_Design/06_Components_Tokens.md): checkbox, title, time metadata, list and priority as text.
/// VoiceOver reads one sentence and offers the actions; every swipe also exists in the menu and the editor.
struct TaskRow: View {
    let task: TaskItem
    var context: TaskRowContext = .list
    @Environment(AppServices.self) private var services
    @State private var editing = false

    private var today: CivilDate { .today() }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
            if context != .trash {
                Button(action: toggle) {
                    Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(task.isCompleted ? Color.accentColor : Color.secondary)
                        .frame(minWidth: TouchTarget.comfort, minHeight: TouchTarget.comfort)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(task.isRecurring)
                .sensoryFeedback(.impact(weight: .light), trigger: task.isCompleted)
            }
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(task.title)
                    .foregroundStyle(task.isCompleted || task.isDeleted ? Color.secondary : Color.primary)
                    .strikethrough(task.isCompleted)
                if let details = details {
                    Text(details)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, context == .trash ? Spacing.sm : 0)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { editing = true }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if canToggle {
                Button(task.isCompleted ? "Rouvrir" : "Terminer", systemImage: task.isCompleted ? "arrow.uturn.backward" : "checkmark", action: toggle)
                    .tint(.green)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if task.isDeleted {
                Button("Restaurer", systemImage: "arrow.uturn.backward", action: restore)
                    .tint(.blue)
            } else {
                Button("Supprimer", systemImage: "trash", role: .destructive, action: delete)
                if canPlan {
                    Button("Demain", systemImage: "calendar", action: { plan(daysFromToday: 1) })
                        .tint(.orange)
                }
            }
        }
        .contextMenu { menu }
        .sheet(isPresented: $editing) {
            TaskEditorView(mode: .edit(task))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySentence)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { editing = true }
        .accessibilityActions { menu }
    }

    @ViewBuilder
    private var menu: some View {
        if canToggle {
            Button(task.isCompleted ? "Rouvrir" : "Marquer comme terminée", systemImage: task.isCompleted ? "arrow.uturn.backward" : "checkmark", action: toggle)
        }
        if canPlan {
            Button("Aujourd’hui", systemImage: "sun.max") { plan(daysFromToday: 0) }
            Button("Demain", systemImage: "calendar") { plan(daysFromToday: 1) }
        }
        Button("Modifier", systemImage: "pencil") { editing = true }
        if task.isDeleted {
            Button("Restaurer", systemImage: "arrow.uturn.backward", action: restore)
        } else {
            Button("Supprimer", systemImage: "trash", role: .destructive, action: delete)
        }
    }

    private var canToggle: Bool { !task.isDeleted && !task.isRecurring }
    private var canPlan: Bool { !task.isDeleted && !task.isCompleted && !task.isRecurring }

    private var details: String? {
        var parts: [String] = []
        if let schedule = task.schedule, context != .trash {
            let text = DateText.moment(schedule, today: today, showDay: context != .today)
            if !text.isEmpty { parts.append(text) }
            if let minutes = task.durationMinutes, schedule.time != nil { parts.append(DurationText.format(minutes)) }
        }
        if let deadline = task.deadline, context != .trash {
            parts.append("échéance " + DateText.moment(deadline, today: today))
        }
        if task.isRecurring { parts.append("répétition") }
        if context != .list, let list = services.directory.name(of: task.projectId) { parts.append(list) }
        if task.priority != .unset { parts.append("priorité " + task.priority.label.lowercased()) }
        if context == .completed, let completedAt = task.completedAt {
            parts.append("terminée " + DateText.day(CivilDate(completedAt), today: today))
        }
        if context == .trash, let deletedAt = task.deletedAt {
            parts.append("supprimée " + DateText.day(CivilDate(deletedAt), today: today))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var accessibilitySentence: String {
        var sentence = task.title
        if let details { sentence += ", " + details }
        if task.isDeleted {
            sentence += ", dans la corbeille"
        } else {
            sentence += task.isCompleted ? ", terminée" : ", non terminée"
        }
        return sentence
    }

    private func toggle() {
        let task = self.task
        let services = self.services
        Task {
            do {
                try await services.tasks.setCompleted(task.id, !task.isCompleted)
                if !task.isCompleted {
                    announce("« \(task.title) » terminée.", services: services) {
                        try? await services.tasks.setCompleted(task.id, false)
                    }
                }
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
        Task { try? await services.tasks.setDeleted(task.id, false) }
    }

    private func plan(daysFromToday days: Int) {
        let task = self.task
        let services = self.services
        let date = CivilDate.today().adding(days: days)
        Task { try? await services.tasks.reschedule(task, to: date) }
    }

    private func announce(_ message: String, services: AppServices, undo: @escaping @MainActor () async -> Void) {
        services.undo.offer(message, undo: undo)
        AccessibilityNotification.Announcement(message).post()
    }
}
