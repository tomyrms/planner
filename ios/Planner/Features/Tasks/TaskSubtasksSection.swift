import SwiftUI

/// Draft-only editing; the parent sheet saves the checklist and the task together.
struct TaskSubtasksSection: View {
    @Binding var subtasks: [TaskSubtask]
    var isRecurring: Bool
    @State private var editMode = EditMode.inactive

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
                    .contextMenu {
                        if let index = subtasks.firstIndex(where: { $0.id == subtask.id }) {
                            if index > 0 { Button("Monter", systemImage: "arrow.up") { move(from: IndexSet(integer: index), to: index - 1) } }
                            if index + 1 < subtasks.count { Button("Descendre", systemImage: "arrow.down") { move(from: IndexSet(integer: index), to: index + 2) } }
                        }
                    }
                    .accessibilityAction(named: Text("Monter")) { move(subtask.id, up: true) }
                    .accessibilityAction(named: Text("Descendre")) { move(subtask.id, up: false) }
                }
                .onMove { source, destination in move(from: source, to: destination) }
                if subtasks.count > 1 {
                    Button(editMode.isEditing ? "Terminer la réorganisation" : "Réorganiser", systemImage: "arrow.up.arrow.down") {
                        editMode = editMode.isEditing ? .inactive : .active
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
        .environment(\.editMode, $editMode)
    }

    private func move(from source: IndexSet, to destination: Int) {
        subtasks = TaskSubtask.moving(subtasks, from: source, to: destination)
    }

    private func move(_ id: String, up: Bool) {
        guard let index = subtasks.firstIndex(where: { $0.id == id }), up ? index > 0 : index + 1 < subtasks.count else { return }
        move(from: IndexSet(integer: index), to: up ? index - 1 : index + 2)
    }
}
