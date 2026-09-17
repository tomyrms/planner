import Foundation
import PowerSync

nonisolated enum ProjectTaskPolicy: String, Sendable {
    case inbox = "move_tasks_to_inbox"
    case trash = "trash_tasks_with_project"
}

nonisolated enum ProjectMutationError: Error, LocalizedError {
    case invalidName, unavailable, restoreListFirst

    var errorDescription: String? {
        switch self {
        case .invalidName: "Le nom de la liste doit contenir entre 1 et 200 caractères."
        case .unavailable: "Cette liste n’est plus disponible. Revenez aux listes pour actualiser."
        case .restoreListFirst: "Restaurez d’abord la liste de cette tâche depuis la Corbeille."
        }
    }
}

nonisolated extension TaskRepository {
    static func validProjectName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf16.count <= 200 else { throw ProjectMutationError.invalidName }
        return name
    }

    func renameProject(_ project: ProjectItem, name: String) async throws {
        let name = try Self.validProjectName(name)
        guard name != project.name else { return }
        let command = LocalCommand(type: "project.patch", aggregateType: "project", aggregateId: project.id,
                                   chaining: .required(revision: project.revision), payload: ["set": ["name": .string(name)]])
        let now = Timestamp.format(Date())
        try await db.writeTransaction { tx in
            try Self.requireProject(project.id, deleted: false, in: tx)
            try tx.execute(sql: "UPDATE projects SET name = ?, updated_at = ? WHERE id = ?", parameters: [name, now, project.id])
            // Search includes the list name, even offline. Derived text does not change task revisions.
            try Self.refreshProjectSearch(project.id, name: name, in: tx)
            try Outbox.insert(command, in: tx)
        }
    }

    func deleteProject(_ project: ProjectItem, policy: ProjectTaskPolicy) async throws {
        let command = LocalCommand(type: "project.delete", aggregateType: "project", aggregateId: project.id,
                                   chaining: .required(revision: project.revision), payload: ["taskPolicy": .string(policy.rawValue)])
        let now = Timestamp.format(Date())
        try await db.writeTransaction { tx in
            try Self.requireProject(project.id, deleted: false, in: tx)
            switch policy {
            case .inbox:
                try Self.recordProjectDependency(project.id, commandId: command.id, where: "1 = 1", in: tx)
                try Self.refreshProjectSearch(project.id, name: nil, in: tx)
                try tx.execute(sql: "UPDATE tasks SET project_id = NULL, updated_at = ? WHERE project_id = ?", parameters: [now, project.id])
            case .trash:
                try Self.recordProjectDependency(project.id, commandId: command.id, where: "deleted_at IS NULL", in: tx)
                try tx.execute(sql: "UPDATE tasks SET deleted_at = ?, deleted_by_command_id = ?, updated_at = ? WHERE project_id = ? AND deleted_at IS NULL",
                               parameters: [now, command.id, now, project.id])
            }
            try tx.execute(sql: "UPDATE projects SET deleted_at = ?, deleted_by_command_id = ?, updated_at = ? WHERE id = ?",
                           parameters: [now, command.id, now, project.id])
            try Outbox.insert(command, in: tx)
        }
    }

    func restoreProject(_ project: ProjectItem) async throws {
        let command = LocalCommand(type: "project.restore", aggregateType: "project", aggregateId: project.id,
                                   chaining: .required(revision: project.revision))
        let now = Timestamp.format(Date())
        try await db.writeTransaction { tx in
            try Self.requireProject(project.id, deleted: true, in: tx)
            let deletion = try tx.get(sql: "SELECT deleted_by_command_id FROM projects WHERE id = ?", parameters: [project.id]) {
                $0.getStringOptional(index: 0)
            }
            if let deletion {
                let ids = try tx.getAll(sql: "SELECT id FROM tasks WHERE project_id = ? AND deleted_by_command_id = ?", parameters: [project.id, deletion]) { try $0.getString(index: 0) }
                for id in ids { try Self.recordTaskDependency(id, commandId: command.id, in: tx) }
                try tx.execute(sql: "UPDATE tasks SET deleted_at = NULL, deleted_by_command_id = NULL, updated_at = ? WHERE project_id = ? AND deleted_by_command_id = ?",
                               parameters: [now, project.id, deletion])
            }
            try tx.execute(sql: "UPDATE projects SET deleted_at = NULL, deleted_by_command_id = NULL, updated_at = ? WHERE id = ?", parameters: [now, project.id])
            try Outbox.insert(command, in: tx)
        }
    }

    private static func requireProject(_ id: String, deleted: Bool, in tx: any Transaction) throws {
        let count = try tx.get(sql: "SELECT count(*) FROM projects WHERE id = ? AND deleted_at IS \(deleted ? "NOT NULL" : "NULL")", parameters: [id]) { try $0.getInt(index: 0) }
        guard count == 1 else { throw ProjectMutationError.unavailable }
    }

    private static func recordProjectDependency(_ projectId: String, commandId: String, where clause: String, in tx: any Transaction) throws {
        let ids = try tx.getAll(sql: "SELECT id FROM tasks WHERE project_id = ? AND \(clause)", parameters: [projectId]) { try $0.getString(index: 0) }
        for id in ids { try recordTaskDependency(id, commandId: commandId, in: tx) }
    }

    private static func recordTaskDependency(_ taskId: String, commandId: String, in tx: any Transaction) throws {
        let key = "task_project_dependency:" + taskId
        try tx.execute(sql: "DELETE FROM local_meta WHERE id = ?", parameters: [key])
        try tx.execute(sql: "INSERT INTO local_meta (id, value) VALUES (?, ?)", parameters: [key, commandId])
    }

    private static func refreshProjectSearch(_ id: String, name: String?, in tx: any Transaction) throws {
        let members = try tx.getAll(sql: "SELECT id, title, notes FROM tasks WHERE project_id = ?", parameters: [id]) {
            (id: try $0.getString(index: 0), title: $0.getStringOptional(index: 1), notes: $0.getStringOptional(index: 2))
        }
        for task in members {
            try tx.execute(sql: "UPDATE tasks SET search_text = ? WHERE id = ?", parameters: [SearchText.normalize([task.title, task.notes, name]), task.id])
        }
    }
}
