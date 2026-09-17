import Foundation
import PowerSync

/// Series, occurrences and reminders (04_Backend/02_API_Contract.md §3.3). Same rule as tasks:
/// one local transaction for the optimistic projection and the queued command.
nonisolated extension TaskRepository {
    // MARK: - Reads

    func observeOccurrences() throws -> AsyncThrowingStream<[OccurrenceRow], any Error> {
        try db.watch(
            sql: """
            SELECT task_id, occurrence_key, status, completed_at, override_date, override_time, override_time_zone, successor_occurrence_key
            FROM task_occurrences
            """,
            parameters: []
        ) { cursor in
            OccurrenceRow(
                taskId: try cursor.getString(name: "task_id"),
                key: try cursor.getString(name: "occurrence_key"),
                status: OccurrenceStatus(rawValue: try cursor.getStringOptional(name: "status") ?? "") ?? .open,
                completedAt: Timestamp.parse(try cursor.getStringOptional(name: "completed_at")),
                override: TimeValue(
                    date: try cursor.getStringOptional(name: "override_date"),
                    time: try cursor.getStringOptional(name: "override_time"),
                    timeZone: try cursor.getStringOptional(name: "override_time_zone")
                ),
                successorKey: try cursor.getStringOptional(name: "successor_occurrence_key")
            )
        }
    }

    func observeReminders() throws -> AsyncThrowingStream<[ReminderRow], any Error> {
        try db.watch(
            sql: """
            SELECT id, task_id, occurrence_key, kind, offset_minutes, local_time, absolute_date, absolute_time, absolute_time_zone, state
            FROM reminders
            """,
            parameters: []
        ) { cursor in
            let rule = ReminderRule(
                kind: try cursor.getStringOptional(name: "kind"),
                offsetMinutes: try cursor.getIntOptional(name: "offset_minutes"),
                localTime: try cursor.getStringOptional(name: "local_time"),
                absoluteDate: try cursor.getStringOptional(name: "absolute_date"),
                absoluteTime: try cursor.getStringOptional(name: "absolute_time"),
                absoluteZone: try cursor.getStringOptional(name: "absolute_time_zone")
            ) ?? .beforeStart(minutes: 0)
            return ReminderRow(
                id: try cursor.getString(name: "id"),
                taskId: try cursor.getStringOptional(name: "task_id") ?? "",
                occurrenceKey: try cursor.getStringOptional(name: "occurrence_key"),
                rule: rule,
                baseMissing: try cursor.getStringOptional(name: "state") == "inactive_base_missing"
            )
        }
    }

    func task(id: String) async throws -> TaskItem? {
        try await db.getOptional(sql: "SELECT \(TaskItem.selectColumns) FROM tasks WHERE id = ?", parameters: [id]) { cursor in
            try TaskItem(row: cursor)
        }
    }

    func occurrenceStatus(taskId: String, key: String) async throws -> OccurrenceStatus? {
        try await db.getOptional(
            sql: "SELECT status FROM task_occurrences WHERE task_id = ? AND occurrence_key = ?",
            parameters: [taskId, key]
        ) { cursor in
            OccurrenceStatus(rawValue: cursor.getStringOptional(index: 0) ?? "") ?? .open
        }
    }

    // MARK: - Occurrences

    /// "Terminer" or "Ignorer" an occurrence. After completion, the successor is previewed with the server's rule.
    func closeOccurrence(_ task: TaskItem, key: String, skip: Bool) async throws {
        let today = CivilDate.today()
        let command = LocalCommand(type: skip ? "occurrence.skip" : "occurrence.complete", aggregateId: task.id, payload: [
            "occurrenceKey": .string(key), "actionLocalDate": .string(today.description),
        ])
        var successor: String?
        if case .afterCompletion(let rule) = task.recurrence {
            successor = OccurrenceKey.next(after: key, date: rule.nextDate(after: today))
        }
        let now = Timestamp.format(Date())
        let status = skip ? "skipped" : "completed"
        let completedAt: String? = skip ? nil : now
        let successorKey = successor
        try await db.writeTransaction { tx in
            let existing = try Self.occurrenceExists(task.id, key, in: tx)
            if existing {
                try tx.execute(
                    sql: """
                    UPDATE task_occurrences SET status = ?, completed_at = ?, successor_occurrence_key = coalesce(successor_occurrence_key, ?), updated_at = ?
                    WHERE task_id = ? AND occurrence_key = ? AND status = 'open'
                    """,
                    parameters: [status, completedAt, successorKey, now, task.id, key]
                )
            } else {
                try tx.execute(
                    sql: """
                    INSERT INTO task_occurrences (id, task_id, occurrence_key, status, completed_at, successor_occurrence_key, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    parameters: [OccurrenceKey.id(taskId: task.id, key: key), task.id, key, status, completedAt, successorKey, now, now]
                )
            }
            try Outbox.insert(command, in: tx)
        }
    }

    func reopenOccurrence(_ task: TaskItem, key: String) async throws {
        let command = LocalCommand(type: "occurrence.reopen", aggregateId: task.id, payload: ["occurrenceKey": .string(key)])
        let now = Timestamp.format(Date())
        try await db.writeTransaction { tx in
            // A reopened row without a move becomes an intact occurrence again (the server deletes it).
            try tx.execute(
                sql: "DELETE FROM task_occurrences WHERE task_id = ? AND occurrence_key = ? AND override_date IS NULL",
                parameters: [task.id, key]
            )
            try tx.execute(
                sql: """
                UPDATE task_occurrences SET status = 'open', completed_at = NULL, successor_occurrence_key = NULL, updated_at = ?
                WHERE task_id = ? AND occurrence_key = ?
                """,
                parameters: [now, task.id, key]
            )
            try Outbox.insert(command, in: tx)
        }
    }

    /// "Déplacer cette occurrence": the key never changes; `nil` cancels the move.
    func rescheduleOccurrence(_ task: TaskItem, key: String, to schedule: TimeValue?) async throws {
        let command = LocalCommand(type: "occurrence.reschedule", aggregateId: task.id, payload: [
            "occurrenceKey": .string(key), "schedule": schedule?.payload ?? .null,
        ])
        let now = Timestamp.format(Date())
        let date = schedule?.date.description
        let time = schedule?.time.map { $0.description + ":00" }
        let zone = schedule?.timeZone
        try await db.writeTransaction { tx in
            if try Self.occurrenceExists(task.id, key, in: tx) {
                try tx.execute(
                    sql: "UPDATE task_occurrences SET override_date = ?, override_time = ?, override_time_zone = ?, updated_at = ? WHERE task_id = ? AND occurrence_key = ?",
                    parameters: [date, time, zone, now, task.id, key]
                )
                if schedule == nil {
                    try tx.execute(
                        sql: "DELETE FROM task_occurrences WHERE task_id = ? AND occurrence_key = ? AND status = 'open'",
                        parameters: [task.id, key]
                    )
                }
            } else if schedule != nil {
                try tx.execute(
                    sql: """
                    INSERT INTO task_occurrences (id, task_id, occurrence_key, status, override_date, override_time, override_time_zone, created_at, updated_at)
                    VALUES (?, ?, ?, 'open', ?, ?, ?, ?, ?)
                    """,
                    parameters: [OccurrenceKey.id(taskId: task.id, key: key), task.id, key, date, time, zone, now, now]
                )
            }
            try Outbox.insert(command, in: tx)
        }
    }

    /// "Ignorer les précédentes": missed occurrences before this key leave the grouped line.
    func skipMissed(before key: String, of task: TaskItem) async throws {
        guard let date = OccurrenceKey.date(of: key) else { return }
        let command = LocalCommand(type: "occurrence.skip_missed_before", aggregateId: task.id, payload: ["occurrenceKey": .string(key)])
        let now = Timestamp.format(Date())
        try await db.writeTransaction { tx in
            try tx.execute(
                sql: """
                UPDATE tasks SET missed_ignored_before = CASE
                  WHEN missed_ignored_before IS NULL OR missed_ignored_before < ? THEN ? ELSE missed_ignored_before END,
                  updated_at = ? WHERE id = ?
                """,
                parameters: [date.description, date.description, now, task.id]
            )
            try Outbox.insert(command, in: tx)
        }
    }

    // MARK: - Series

    /// "Toute la série": rule and task template in one `series.update` (revision precondition required).
    func updateSeries(_ task: TaskItem, from base: TaskDraft, to draft: TaskDraft) async throws {
        var set: [String: JSONPayload] = [:]
        if draft.trimmedTitle != base.trimmedTitle { set["title"] = .string(draft.trimmedTitle) }
        if draft.notes != base.notes { set["notes"] = draft.notes.isEmpty ? .null : .string(draft.notes) }
        if draft.priority != base.priority { set["priority"] = .string(draft.priority.rawValue) }
        if draft.projectId != base.projectId { set["projectId"] = draft.projectId.map { JSONPayload.string($0) } ?? .null }
        if draft.durationMinutes != base.durationMinutes { set["durationMinutes"] = draft.durationMinutes.map { JSONPayload.int($0) } ?? .null }
        if draft.schedule != base.schedule, let schedule = draft.schedule { set["schedule"] = schedule.payload }
        var payload: [String: JSONPayload] = [:]
        if !set.isEmpty { payload["set"] = .object(set) }
        if draft.recurrence != base.recurrence, let recurrence = draft.recurrence { payload["recurrence"] = recurrence.payload }
        let reminderChanged = draft.reminder != base.reminder
        guard !payload.isEmpty || reminderChanged else { return }
        let now = Timestamp.format(Date())
        let schedule = draft.schedule
        let recurrenceText = try draft.recurrence?.payload.encodedText()
        let seriesCommand = payload.isEmpty ? nil : LocalCommand(
            type: "series.update", aggregateId: task.id, chaining: .required(revision: task.revision), payload: .object(payload)
        )
        try await db.writeTransaction { tx in
            if let seriesCommand {
                let projectName = try Self.projectNameInTransaction(draft.projectId, in: tx)
                try tx.execute(
                    sql: """
                    UPDATE tasks SET title = ?, notes = ?, priority = ?, project_id = ?, duration_minutes = ?,
                           scheduled_date = ?, scheduled_time = ?, scheduled_time_zone = ?, recurrence = ?, search_text = ?, updated_at = ?
                    WHERE id = ?
                    """,
                    parameters: [
                        draft.trimmedTitle, draft.notes.isEmpty ? nil : draft.notes, draft.priority.rawValue, draft.projectId,
                        draft.durationMinutes, schedule?.date.description, schedule?.time.map { $0.description + ":00" },
                        schedule?.timeZone, recurrenceText, SearchText.normalize([draft.trimmedTitle, draft.notes, projectName]), now, task.id,
                    ]
                )
                try Outbox.insert(seriesCommand, in: tx)
            }
            if reminderChanged {
                try Self.writeReminder(task: task.id, existingId: base.reminderId, rule: draft.reminder, schedule: schedule, deadline: nil, in: tx)
            }
        }
    }

    /// "Arrêter la série" (`series.end`, revision precondition required). `task.reopen` resumes it.
    func endSeries(_ task: TaskItem) async throws {
        let command = LocalCommand(type: "series.end", aggregateId: task.id, chaining: .required(revision: task.revision))
        let now = Timestamp.format(Date())
        try await db.writeTransaction { tx in
            try tx.execute(sql: "UPDATE tasks SET status = 'completed', completed_at = ?, updated_at = ? WHERE id = ?", parameters: [now, now, task.id])
            try Outbox.insert(command, in: tx)
        }
    }

    // MARK: - Reminders

    /// The single reminder of a simple task: set, replace or remove (`reminder.set` / `reminder.remove`).
    func setReminder(taskId: String, existingId: String?, rule: ReminderRule?, schedule: TimeValue?, deadline: TimeValue?) async throws {
        try await db.writeTransaction { tx in
            try Self.writeReminder(task: taskId, existingId: existingId, rule: rule, schedule: schedule, deadline: deadline, in: tx)
        }
    }

    static func writeReminder(task taskId: String, existingId: String?, rule: ReminderRule?, schedule: TimeValue?, deadline: TimeValue?, in tx: any Transaction) throws {
        let now = Timestamp.format(Date())
        guard let rule else {
            guard let existingId else { return }
            try tx.execute(sql: "DELETE FROM reminders WHERE id = ?", parameters: [existingId])
            try Outbox.insert(LocalCommand(type: "reminder.remove", aggregateId: taskId, payload: ["id": .string(existingId)]), in: tx)
            return
        }
        let id = existingId ?? UUID().uuidString.lowercased()
        try tx.execute(sql: "DELETE FROM reminders WHERE id = ?", parameters: [id])
        try insertReminderRow(id: id, taskId: taskId, rule: rule, schedule: schedule, deadline: deadline, now: now, in: tx)
        try Outbox.insert(LocalCommand(type: "reminder.set", aggregateId: taskId, payload: ["id": .string(id), "rule": rule.payload]), in: tx)
    }

    static func insertReminderRow(id: String, taskId: String, rule: ReminderRule, schedule: TimeValue?, deadline: TimeValue?, now: String, in tx: any Transaction) throws {
        var offset: Int?
        var localTime: String?
        var absolute: TimeValue?
        switch rule {
        case .beforeStart(let minutes), .beforeDeadline(let minutes): offset = minutes
        case .onScheduledDay(let time), .onDeadlineDay(let time): localTime = time.description + ":00"
        case .absolute(let value): absolute = value
        }
        let missing = ReminderMath.trigger(rule, schedule: schedule, deadline: deadline, deviceZone: .current) == .baseMissing
        let parameters: [Sendable?] = [
            id, taskId, rule.kind, offset, localTime, absolute?.date.description,
            absolute?.time.map { $0.description + ":00" }, absolute?.timeZone,
            missing ? "inactive_base_missing" : "active", now, now,
        ]
        try tx.execute(
            sql: """
            INSERT INTO reminders (id, task_id, kind, offset_minutes, local_time, absolute_date, absolute_time, absolute_time_zone, state, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            parameters: parameters
        )
    }

    /// After a planning change the server recomputes reminder bases; the projection does the same.
    static func refreshReminderStates(taskId: String, schedule: TimeValue?, deadline: TimeValue?, in tx: any Transaction) throws {
        let rows = try tx.getAll(
            sql: "SELECT id, kind, offset_minutes, local_time, absolute_date, absolute_time, absolute_time_zone FROM reminders WHERE task_id = ?",
            parameters: [taskId]
        ) { cursor in
            (
                id: try cursor.getString(index: 0),
                rule: ReminderRule(
                    kind: cursor.getStringOptional(index: 1), offsetMinutes: cursor.getIntOptional(index: 2),
                    localTime: cursor.getStringOptional(index: 3), absoluteDate: cursor.getStringOptional(index: 4),
                    absoluteTime: cursor.getStringOptional(index: 5), absoluteZone: cursor.getStringOptional(index: 6)
                )
            )
        }
        for row in rows {
            guard let rule = row.rule else { continue }
            let missing = ReminderMath.trigger(rule, schedule: schedule, deadline: deadline, deviceZone: .current) == .baseMissing
            try tx.execute(
                sql: "UPDATE reminders SET state = ? WHERE id = ?",
                parameters: [missing ? "inactive_base_missing" : "active", row.id]
            )
        }
    }

    private static func occurrenceExists(_ taskId: String, _ key: String, in tx: any Transaction) throws -> Bool {
        try tx.getOptional(
            sql: "SELECT 1 FROM task_occurrences WHERE task_id = ? AND occurrence_key = ?",
            parameters: [taskId, key]
        ) { cursor in try cursor.getInt(index: 0) } != nil
    }

    static func projectNameInTransaction(_ id: String?, in tx: any Transaction) throws -> String? {
        guard let id else { return nil }
        return try tx.getOptional(sql: "SELECT name FROM projects WHERE id = ?", parameters: [id]) { cursor in
            cursor.getStringOptional(index: 0) ?? ""
        }
    }
}
