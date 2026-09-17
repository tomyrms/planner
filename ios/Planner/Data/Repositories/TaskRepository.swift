import Foundation
import PowerSync

/// The only way screens read and change tasks and lists. Every manual change is one local transaction:
/// optimistic projection + queued command (03_iOS/02_Local_Data_Sync.md). The UI never sees PowerSync.
nonisolated struct TaskRepository: Sendable {
    let db: any PowerSyncDatabaseProtocol

    // MARK: - Reads

    func observeTasks(_ filter: TaskFilter) throws -> AsyncThrowingStream<[TaskItem], any Error> {
        let (clause, parameters) = Self.query(for: filter)
        return try db.watch(
            sql: "SELECT \(TaskItem.selectColumns) FROM tasks WHERE \(clause)",
            parameters: parameters
        ) { cursor in try TaskItem(row: cursor) }
    }

    func observeTask(id: String) throws -> AsyncThrowingStream<[TaskItem], any Error> {
        try db.watch(sql: "SELECT \(TaskItem.selectColumns) FROM tasks WHERE id = ?", parameters: [id]) { cursor in
            try TaskItem(row: cursor)
        }
    }

    func observeProjects() throws -> AsyncThrowingStream<[ProjectItem], any Error> {
        try db.watch(
            sql: """
            SELECT p.id, p.name,
                   (SELECT count(*) FROM tasks t WHERE t.project_id = p.id AND t.deleted_at IS NULL AND t.status = 'active') AS active_count
            FROM projects p
            WHERE p.deleted_at IS NULL AND p.archived_at IS NULL
            ORDER BY p.sort_order IS NULL, p.sort_order, p.name COLLATE NOCASE
            """,
            parameters: []
        ) { cursor in
            ProjectItem(id: try cursor.getString(name: "id"), name: try cursor.getStringOptional(name: "name") ?? "", activeTaskCount: try cursor.getInt(name: "active_count"))
        }
    }

    func observeInboxCount() throws -> AsyncThrowingStream<[Int], any Error> {
        try db.watch(
            sql: "SELECT count(*) FROM tasks WHERE project_id IS NULL AND deleted_at IS NULL AND status = 'active'",
            parameters: []
        ) { cursor in try cursor.getInt(index: 0) }
    }

    private static func query(for filter: TaskFilter) -> (String, [Sendable?]) {
        switch filter {
        case .inbox:
            ("deleted_at IS NULL AND status = 'active' AND project_id IS NULL ORDER BY created_at DESC", [])
        case .project(let id):
            ("deleted_at IS NULL AND status = 'active' AND project_id = ? ORDER BY scheduled_date IS NULL, scheduled_date, created_at DESC", [id])
        case .dated:
            ("""
            deleted_at IS NULL AND status = 'active'
            AND (scheduled_date IS NOT NULL OR deadline_date IS NOT NULL)
            ORDER BY coalesce(scheduled_date, deadline_date), scheduled_time IS NULL, scheduled_time
            """, [])
        case .completed:
            ("deleted_at IS NULL AND status = 'completed' ORDER BY completed_at DESC LIMIT 500", [])
        case .trash:
            ("deleted_at IS NOT NULL ORDER BY deleted_at DESC", [])
        case .search(let text):
            ("deleted_at IS NULL AND search_text LIKE ? ESCAPE '\\' ORDER BY status, created_at DESC LIMIT 200",
             ["%" + Self.likeEscaped(SearchText.normalize([text])) + "%"])
        }
    }

    private static func likeEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    // MARK: - Writes

    @discardableResult
    func create(_ draft: TaskDraft) async throws -> String {
        let id = UUID().uuidString.lowercased()
        var payload: [String: JSONPayload] = ["title": .string(draft.trimmedTitle)]
        if !draft.notes.isEmpty { payload["notes"] = .string(draft.notes) }
        if draft.priority != .unset { payload["priority"] = .string(draft.priority.rawValue) }
        if let projectId = draft.projectId { payload["projectId"] = .string(projectId) }
        if let schedule = draft.schedule { payload["schedule"] = schedule.payload }
        if let deadline = draft.deadline { payload["deadline"] = deadline.payload }
        if let minutes = draft.durationMinutes { payload["durationMinutes"] = .int(minutes) }
        if let recurrence = draft.recurrence { payload["recurrence"] = recurrence.payload }
        let reminderId = UUID().uuidString.lowercased()
        if let rule = draft.reminder {
            payload["reminders"] = [["id": .string(reminderId), "rule": rule.payload]]
        }
        let recurrenceText = try draft.recurrence?.payload.encodedText()
        let command = LocalCommand(type: "task.create", aggregateId: id, chaining: .never, payload: .object(payload))
        let columns = TaskColumns(draft)
        let now = Timestamp.format(Date())
        try await db.writeTransaction { tx in
            let projectName = try Self.projectName(draft.projectId, in: tx)
            try tx.execute(
                sql: """
                INSERT INTO tasks (id, project_id, title, notes, priority, scheduled_date, scheduled_time, scheduled_time_zone,
                                   duration_minutes, deadline_date, deadline_time, deadline_time_zone, search_text,
                                   created_at, updated_at, status, revision)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', 0)
                """,
                parameters: columns.parameters(prefix: [id], searchText: SearchText.normalize([draft.trimmedTitle, draft.notes, projectName]), suffix: [now, now])
            )
            if let recurrenceText {
                try tx.execute(sql: "UPDATE tasks SET recurrence = ? WHERE id = ?", parameters: [recurrenceText, id])
            }
            if let rule = draft.reminder {
                try Self.insertReminderRow(id: reminderId, taskId: id, rule: rule, schedule: draft.schedule, deadline: draft.deadline, now: now, in: tx)
            }
            try Outbox.insert(command, in: tx)
        }
        return id
    }

    /// One `task.patch` with the fields that changed; nothing is queued when nothing changed.
    func update(_ id: String, from base: TaskDraft, to draft: TaskDraft, reapplying fields: Set<String> = []) async throws {
        let set = Self.patch(from: base, to: draft, reapplying: fields)
        let reminderChanged = draft.reminder != base.reminder
        guard !set.isEmpty || reminderChanged else { return }
        let command = set.isEmpty ? nil : LocalCommand(type: "task.patch", aggregateId: id, payload: .object(["set": .object(set)]))
        let columns = TaskColumns(draft)
        let now = Timestamp.format(Date())
        try await db.writeTransaction { tx in
            let projectName = try Self.projectName(draft.projectId, in: tx)
            try tx.execute(
                sql: """
                UPDATE tasks SET project_id = ?, title = ?, notes = ?, priority = ?,
                       scheduled_date = ?, scheduled_time = ?, scheduled_time_zone = ?, duration_minutes = ?,
                       deadline_date = ?, deadline_time = ?, deadline_time_zone = ?, search_text = ?, updated_at = ?
                WHERE id = ?
                """,
                parameters: columns.parameters(prefix: [], searchText: SearchText.normalize([draft.trimmedTitle, draft.notes, projectName]), suffix: [now, id])
            )
            // The planning change comes first: a new reminder then refers to the new base.
            if let command { try Outbox.insert(command, in: tx) }
            try Self.refreshReminderStates(taskId: id, schedule: draft.schedule, deadline: draft.deadline, in: tx)
            if reminderChanged {
                try Self.writeReminder(task: id, existingId: base.reminderId, rule: draft.reminder, schedule: draft.schedule, deadline: draft.deadline, in: tx)
            }
        }
    }

    /// Explicit correction of a rejection: its reviewed fields must be sent even while the local
    /// optimistic projection still contains their refused values. No old identifier/precondition is reused.
    static func patch(from base: TaskDraft, to draft: TaskDraft, reapplying fields: Set<String>) -> [String: JSONPayload] {
        var set = draft.changes(from: base)
        let values: [String: JSONPayload] = [
            "title": .string(draft.trimmedTitle),
            "notes": draft.notes.isEmpty ? .null : .string(draft.notes),
            "priority": .string(draft.priority.rawValue),
            "projectId": draft.projectId.map(JSONPayload.string) ?? .null,
            "schedule": draft.schedule?.payload ?? .null,
            "deadline": draft.deadline?.payload ?? .null,
            "durationMinutes": draft.durationMinutes.map(JSONPayload.int) ?? .null,
        ]
        for field in fields { if let value = values[field] { set[field] = value } }
        return set
    }

    /// Quick planning from a row: keeps the time and zone, changes the day only.
    func reschedule(_ task: TaskItem, to date: CivilDate) async throws {
        var draft = TaskDraft(task: task)
        draft.schedule = TimeValue(date: date, time: task.schedule?.time, timeZone: task.schedule?.timeZone)
        try await update(task.id, from: TaskDraft(task: task), to: draft)
    }

    func setCompleted(_ id: String, _ completed: Bool) async throws {
        let command = LocalCommand(type: completed ? "task.complete" : "task.reopen", aggregateId: id)
        let now = Timestamp.format(Date())
        try await db.writeTransaction { tx in
            try tx.execute(
                sql: "UPDATE tasks SET status = ?, completed_at = ?, updated_at = ? WHERE id = ?",
                parameters: [completed ? "completed" : "active", completed ? now : nil, now, id]
            )
            try Outbox.insert(command, in: tx)
        }
    }

    func setDeleted(_ id: String, _ deleted: Bool) async throws {
        let command = LocalCommand(type: deleted ? "task.delete" : "task.restore", aggregateId: id)
        let now = Timestamp.format(Date())
        try await db.writeTransaction { tx in
            try tx.execute(
                sql: "UPDATE tasks SET deleted_at = ?, updated_at = ? WHERE id = ?",
                parameters: [deleted ? now : nil, now, id]
            )
            try Outbox.insert(command, in: tx)
        }
    }

    @discardableResult
    func createProject(name: String) async throws -> String {
        let id = UUID().uuidString.lowercased()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = LocalCommand(type: "project.create", aggregateType: "project", aggregateId: id, chaining: .never, payload: ["name": .string(trimmed)])
        let now = Timestamp.format(Date())
        try await db.writeTransaction { tx in
            try tx.execute(
                sql: "INSERT INTO projects (id, name, revision, created_at, updated_at) VALUES (?, ?, 0, ?, ?)",
                parameters: [id, trimmed, now, now]
            )
            try Outbox.insert(command, in: tx)
        }
        return id
    }

    private static func projectName(_ id: String?, in tx: any Transaction) throws -> String? {
        guard let id else { return nil }
        return try tx.getOptional(sql: "SELECT name FROM projects WHERE id = ?", parameters: [id]) { cursor in
            cursor.getStringOptional(index: 0) ?? ""
        }
    }

}

/// Column values of the optimistic projection, in the order of `TaskRepository`'s statements.
private nonisolated struct TaskColumns {
    let projectId: String?
    let title: String
    let notes: String?
    let priority: String
    let scheduledDate: String?
    let scheduledTime: String?
    let scheduledTimeZone: String?
    let durationMinutes: Int?
    let deadlineDate: String?
    let deadlineTime: String?
    let deadlineTimeZone: String?

    init(_ draft: TaskDraft) {
        projectId = draft.projectId
        title = draft.trimmedTitle
        notes = draft.notes.isEmpty ? nil : draft.notes
        priority = draft.priority.rawValue
        scheduledDate = draft.schedule?.date.description
        scheduledTime = Self.stored(draft.schedule?.time)
        scheduledTimeZone = draft.schedule?.timeZone
        durationMinutes = draft.durationMinutes
        deadlineDate = draft.deadline?.date.description
        deadlineTime = Self.stored(draft.deadline?.time)
        deadlineTimeZone = draft.deadline?.timeZone
    }

    func parameters(prefix: [Sendable?], searchText: String, suffix: [Sendable?]) -> [Sendable?] {
        let values: [Sendable?] = [
            projectId, title, notes, priority, scheduledDate, scheduledTime, scheduledTimeZone,
            durationMinutes, deadlineDate, deadlineTime, deadlineTimeZone, searchText,
        ]
        return prefix + values + suffix
    }

    /// Same text as the server's `time` column.
    private static func stored(_ time: LocalTime?) -> String? {
        guard let time else { return nil }
        return time.description + ":00"
    }
}

/// The local queue and its rejections, for Settings > Synchronisation.
nonisolated struct SyncQueueRepository: Sendable {
    let db: any PowerSyncDatabaseProtocol

    nonisolated struct Rejection: Identifiable, Hashable, Sendable {
        let id: String
        let commandType: String
        let aggregateId: String
        let code: String
        let rejectedAt: Date?
        var commandJSON: String? = nil
    }

    func pending() async throws -> (count: Int, oldest: Date?) {
        try await Outbox.pendingSummary(in: db)
    }

    func observeRejections() throws -> AsyncThrowingStream<[Rejection], any Error> {
        try db.watch(
            sql: "SELECT id, command_type, aggregate_id, code, rejected_at, command_json FROM sync_rejections ORDER BY rejected_at DESC",
            parameters: []
        ) { cursor in
            Rejection(
                id: try cursor.getString(name: "id"),
                commandType: try cursor.getStringOptional(name: "command_type") ?? "",
                aggregateId: try cursor.getStringOptional(name: "aggregate_id") ?? "",
                code: try cursor.getStringOptional(name: "code") ?? "UNKNOWN",
                rejectedAt: Timestamp.parse(try cursor.getStringOptional(name: "rejected_at")),
                commandJSON: try cursor.getStringOptional(name: "command_json")
            )
        }
    }

    func rejection(id: String) async throws -> Rejection? {
        try await db.getOptional(
            sql: "SELECT id, command_type, aggregate_id, code, rejected_at, command_json FROM sync_rejections WHERE lower(id) = lower(?)",
            parameters: [id]
        ) { cursor in
            Rejection(
                id: try cursor.getString(name: "id"),
                commandType: try cursor.getStringOptional(name: "command_type") ?? "",
                aggregateId: try cursor.getStringOptional(name: "aggregate_id") ?? "",
                code: try cursor.getStringOptional(name: "code") ?? "UNKNOWN",
                rejectedAt: Timestamp.parse(try cursor.getStringOptional(name: "rejected_at")),
                commandJSON: try cursor.getStringOptional(name: "command_json")
            )
        }
    }

    /// "Ignorer": local-only table, nothing is uploaded.
    func dismiss(_ rejection: Rejection) async throws {
        try await db.execute(sql: "DELETE FROM sync_rejections WHERE id = ?", parameters: [rejection.id])
    }

    func serverGeneration() async throws -> String? {
        try await LocalMeta.serverGeneration(in: db)
    }
}
