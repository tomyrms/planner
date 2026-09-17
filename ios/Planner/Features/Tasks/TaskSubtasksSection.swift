import SwiftUI

/// Draft-only editing; the parent sheet saves the checklist and the task together.
struct TaskSubtasksSection: View {
    @Binding var subtasks: [TaskSubtask]
    var isRecurring: Bool

    var body: some View {
        Section {
            if isRecurring {
                Text("Les sous-tâches sont disponibles pour les tâches sans répétition.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach($subtasks) { $subtask in
                    HStack(alignment: .top, spacing: Spacing.sm) {
                        Button {
                            subtask.isCompleted.toggle()
                        } label: {
                            Image(systemName: subtask.isCompleted ? "checkmark.circle.fill" : "circle")
                                .frame(minWidth: TouchTarget.comfort, minHeight: TouchTarget.comfort)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(subtask.title.isEmpty ? "Sous-tâche" : subtask.title)
                        .accessibilityValue(subtask.isCompleted ? "Terminée" : "À faire")
                        .accessibilityHint(subtask.isCompleted ? "Marquer comme à faire" : "Marquer comme terminée")
                        TextField("Titre de la sous-tâche", text: $subtask.title, axis: .vertical)
                            .frame(minHeight: TouchTarget.comfort)
                        Button("Retirer la sous-tâche", systemImage: "minus.circle", role: .destructive) {
                            subtasks.removeAll { $0.id == subtask.id }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .frame(minWidth: TouchTarget.comfort, minHeight: TouchTarget.comfort)
                    }
                }
                Button("Ajouter une sous-tâche", systemImage: "plus") {
                    let order = (subtasks.map(\.sortOrder).max() ?? -1) + 1
                    subtasks.append(TaskSubtask(title: "", sortOrder: order))
                }
                .disabled(subtasks.count >= 50)
            }
        } header: {
            Text("Sous-tâches")
        } footer: {
            if !isRecurring {
                Text("Chaque sous-tâche a besoin d’un titre, jusqu’à 500 caractères. Cocher les sous-tâches ne termine pas automatiquement la tâche. Jusqu’à 50 sous-tâches.")
            }
        }
    }
}
