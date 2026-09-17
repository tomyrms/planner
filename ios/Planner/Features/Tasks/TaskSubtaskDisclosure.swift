import SwiftUI

/// A separate target beside the task title: expanding never opens or completes the task.
struct TaskSubtaskDisclosureButton: View {
    let taskTitle: String
    let subtasks: [TaskSubtask]
    @Binding var isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: Spacing.xs) {
                Text("\(subtasks.filter(\.isCompleted).count)/\(subtasks.count)")
                    .font(.caption.monospacedDigit())
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .foregroundStyle(Color.secondary)
            .frame(minWidth: TouchTarget.comfort, minHeight: TouchTarget.comfort)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel((isExpanded ? "Masquer les sous-tâches de « " : "Afficher les sous-tâches de « ") + taskTitle + " »")
        .accessibilityValue("\(subtasks.filter(\.isCompleted).count) terminées sur \(subtasks.count)")
    }
}

/// Read-only overview. Editing and checking subtasks stay in the task's existing editor.
struct TaskSubtaskList: View {
    let subtasks: [TaskSubtask]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ForEach(TaskSubtask.sorted(subtasks)) { subtask in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                    Image(systemName: subtask.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(subtask.title)
                        .font(.subheadline)
                        .strikethrough(subtask.isCompleted)
                        .foregroundStyle(subtask.isCompleted ? Color.secondary : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(subtask.title + (subtask.isCompleted ? ", sous-tâche terminée" : ", sous-tâche non terminée"))
            }
        }
        .padding(.top, Spacing.xs)
        .padding(.bottom, Spacing.md)
    }
}

/// Anonymous component board for CI review; no services or database are created.
struct TaskSubtasksPreview: View {
    let expanded: Bool
    private let subtasks = [
        TaskSubtask(title: "Relire le chapitre", isCompleted: true, sortOrder: 0),
        TaskSubtask(title: "Préparer les exercices pour la séance de demain", sortOrder: 1),
        TaskSubtask(title: "Vérifier les réponses", sortOrder: 2),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Aujourd’hui").font(.title2.weight(.semibold))
            HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
                Image(systemName: "circle").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Préparer le cours").font(.body)
                    Text("17:00 · 45 min").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                TaskSubtaskDisclosureButton(taskTitle: "Préparer le cours", subtasks: subtasks, isExpanded: .constant(expanded))
            }
            if expanded { TaskSubtaskList(subtasks: subtasks).padding(.leading, Spacing.xl) }
            Divider()
            Spacer()
        }
        .padding(Spacing.lg)
        .background(Color(uiColor: .systemBackground))
    }
}

#Preview("Sous-tâches ouvertes") { TaskSubtasksPreview(expanded: true) }
#Preview("Sous-tâches repliées") { TaskSubtasksPreview(expanded: false) }
