import SwiftUI

/// "Modifié par l'assistant": the task keeps the link to the assistant's changes, with Annuler for 24 h.
struct AssistantChangesSection: View {
    let taskId: String
    @Environment(AppServices.self) private var services
    @State private var changes: [AssistantChange] = []

    var body: some View {
        Group {
            if !changes.isEmpty {
                Section("Modifié par l’assistant") {
                    ForEach(changes) { change in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Self.label(change))
                                if let createdAt = change.createdAt {
                                    Text(createdAt.formatted(.relative(presentation: .named)))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if change.canUndo {
                                Button("Annuler") {
                                    Task { await services.assistant.undo(actionId: change.id) }
                                }
                                .buttonStyle(.borderless)
                                .disabled(services.assistant.busy.contains(change.id))
                            } else if change.undoState == "undone" {
                                Text("Annulée")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let notice = services.assistant.notice {
                        Text(notice)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .task(id: taskId) {
            do {
                for try await rows in try services.assistantHistory.observeActions(taskId: taskId) {
                    changes = rows
                }
            } catch {}
        }
    }

    private static func label(_ change: AssistantChange) -> String {
        if change.isUndo { return "Annulation" }
        switch change.commandType {
        case "task.create": return "Créée"
        case "task.patch": return "Modifiée"
        case "task.complete", "occurrence.complete": return "Terminée"
        case "task.reopen", "occurrence.reopen": return "Rouverte"
        case "task.delete": return "Mise à la corbeille"
        case "task.restore": return "Restaurée"
        case "occurrence.reschedule": return "Occurrence déplacée"
        case "occurrence.skip": return "Occurrence ignorée"
        case "series.update": return "Série modifiée"
        case "series.end": return "Série terminée"
        case "reminder.set": return "Rappel réglé"
        case "reminder.remove": return "Rappel retiré"
        default: return "Modifiée"
        }
    }
}
