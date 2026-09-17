import Foundation
import PowerSync

/// One active catalogue tag and, when present, one current assignment. Completed/trashed tasks
/// keep their visible labels; only active tasks contribute to the catalogue count.
nonisolated struct TagDirectoryRow: Sendable {
    let tag: TagItem
    let taskId: String?
    let activeTask: Bool
}

nonisolated struct TagTaskSummary: Identifiable, Equatable, Sendable {
    let tag: TagItem
    var activeTaskCount: Int
    var id: String { tag.id }
}

nonisolated struct TagDirectorySnapshot: Equatable, Sendable {
    var catalogue: [TagTaskSummary] = []
    var taskTags: [String: [TagItem]] = [:]

    init(rows: [TagDirectoryRow] = []) {
        var indexByTag: [String: Int] = [:]
        for row in rows {
            let index: Int
            if let existing = indexByTag[row.tag.id] {
                index = existing
            } else {
                index = catalogue.count
                indexByTag[row.tag.id] = index
                catalogue.append(TagTaskSummary(tag: row.tag, activeTaskCount: 0))
            }
            if let taskId = row.taskId {
                taskTags[taskId, default: []].append(row.tag)
                if row.activeTask { catalogue[index].activeTaskCount += 1 }
            }
        }
    }
}

nonisolated extension TaskRepository {
    /// A single observation feeds every task row and the Tags section, including local edits.
    func observeTagDirectory() throws -> AsyncThrowingStream<[TagDirectoryRow], any Error> {
        try db.watch(sql: Self.tagDirectorySQL, parameters: [], mapper: Self.tagDirectoryRow)
    }

    func tagDirectorySnapshot() async throws -> TagDirectorySnapshot {
        let rows = try await db.getAll(sql: Self.tagDirectorySQL, parameters: [], mapper: Self.tagDirectoryRow)
        return TagDirectorySnapshot(rows: rows)
    }

    func observeTasks(tagId: String) throws -> AsyncThrowingStream<[TaskItem], any Error> {
        try db.watch(sql: Self.tasksForTagSQL, parameters: [tagId.lowercased()]) { try TaskItem(row: $0) }
    }

    func tasks(tagId: String) async throws -> [TaskItem] {
        try await db.getAll(sql: Self.tasksForTagSQL, parameters: [tagId.lowercased()]) { try TaskItem(row: $0) }
    }

    private static let tagDirectorySQL = """
        SELECT DISTINCT g.id AS tag_id, g.name AS tag_name, t.id AS task_id,
               CASE WHEN t.status = 'active' AND t.deleted_at IS NULL THEN 1 ELSE 0 END AS active_task
        FROM tags g
        LEFT JOIN task_tags link ON link.tag_id = g.id AND link.deleted_at IS NULL
        LEFT JOIN tasks t ON t.id = link.task_id
        WHERE g.deleted_at IS NULL
        ORDER BY g.name COLLATE NOCASE, g.id, t.id
        """

    private static func tagDirectoryRow(_ row: any SqlCursor) throws -> TagDirectoryRow {
        TagDirectoryRow(
            tag: TagItem(id: try row.getString(name: "tag_id"), name: try row.getString(name: "tag_name"), deletedAt: nil),
            taskId: try row.getStringOptional(name: "task_id"),
            activeTask: try row.getInt(name: "active_task") == 1
        )
    }

    private static var tasksForTagSQL: String {
        """
        SELECT \(TaskItem.selectColumns) FROM tasks
        WHERE deleted_at IS NULL AND EXISTS (
            SELECT 1 FROM task_tags link JOIN tags g ON g.id = link.tag_id
            WHERE link.task_id = tasks.id AND link.tag_id = ?
              AND link.deleted_at IS NULL AND g.deleted_at IS NULL
        )
        ORDER BY scheduled_date IS NULL, scheduled_date, scheduled_time IS NULL, scheduled_time, created_at DESC, id
        """
    }
}
