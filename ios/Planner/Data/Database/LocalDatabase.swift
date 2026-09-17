import Foundation
import PowerSync

/// Local SQLite schema: the synced columns of `powersync/sync-config.yaml`, plus the command queue
/// and two local-only tables (03_iOS/02_Local_Data_Sync.md). PowerSync adds `id` to every table.
nonisolated enum LocalDatabase {
    static let fileName = "planner.sqlite"

    static let schema = Schema(
        Table(name: "projects", columns: [
            .text("name"), .text("color_key"), .real("sort_order"), .text("archived_at"), .text("deleted_at"),
            .integer("revision"), .text("created_at"), .text("updated_at"),
        ]),
        Table(name: "tasks", columns: [
            .text("project_id"), .text("title"), .text("notes"), .text("priority"), .text("status"), .text("completed_at"),
            .text("scheduled_date"), .text("scheduled_time"), .text("scheduled_time_zone"), .text("scheduled_start_at"),
            .integer("duration_minutes"),
            .text("deadline_date"), .text("deadline_time"), .text("deadline_time_zone"), .text("deadline_at"),
            .text("recurrence"), .text("missed_ignored_before"), .text("search_text"), .text("deleted_at"),
            .integer("revision"), .text("created_at"), .text("updated_at"),
        ], indexes: [
            Index.ascending(name: "project", column: "project_id"),
            Index.ascending(name: "scheduled", column: "scheduled_date"),
            Index.ascending(name: "deadline", column: "deadline_date"),
        ]),
        Table(name: "task_occurrences", columns: [
            .text("task_id"), .text("occurrence_key"), .text("status"), .text("completed_at"),
            .text("override_date"), .text("override_time"), .text("override_time_zone"), .text("successor_occurrence_key"),
            .text("created_at"), .text("updated_at"),
        ], indexes: [Index.ascending(name: "task", column: "task_id")]),
        Table(name: "reminders", columns: [
            .text("task_id"), .text("occurrence_key"), .text("kind"), .integer("offset_minutes"), .text("local_time"),
            .text("absolute_date"), .text("absolute_time"), .text("absolute_time_zone"), .text("state"),
            .text("created_at"), .text("updated_at"),
        ], indexes: [Index.ascending(name: "task", column: "task_id")]),
        Table(name: "server_meta", columns: [.text("generation")]),
        // Assistant history, read-only on the phone (ADR-029): changed only through the assistant routes.
        Table(name: "conversations", columns: [.text("title"), .text("created_at"), .text("updated_at")]),
        Table(name: "messages", columns: [
            .text("conversation_id"), .integer("seq"), .text("role"), .text("kind"), .text("text"),
            .text("original_transcript"), .text("transcription_id"), .text("turn_id"), .text("revises_message_id"), .text("created_at"),
        ], indexes: [Index.ascending(name: "conversation", columns: ["conversation_id", "seq"])]),
        Table(name: "assistant_turns", columns: [
            .text("conversation_id"), .text("user_message_id"), .text("status"), .text("risk_class"),
            .text("reply_message_id"), .text("error_code"), .text("created_at"), .text("finished_at"),
        ], indexes: [Index.ascending(name: "conversation", column: "conversation_id")]),
        Table(name: "assistant_proposals", columns: [
            .text("turn_id"), .text("plan_hash"), .text("preview"), .text("state"), .text("expires_at"),
            .text("decided_at"), .text("created_at"),
        ], indexes: [Index.ascending(name: "turn", column: "turn_id")]),
        Table(name: "ai_actions", columns: [
            .text("group_id"), .integer("plan_index"), .text("turn_id"), .text("proposal_id"), .text("aggregate_type"),
            .text("aggregate_id"), .text("command_type"), .text("changes"), .integer("resulting_revision"),
            .text("undo_state"), .text("undo_expires_at"), .text("undo_of_action_id"), .text("created_at"),
        ], indexes: [
            Index.ascending(name: "turn", column: "turn_id"),
            Index.ascending(name: "aggregate", column: "aggregate_id"),
        ]),
        // One insert-only row per manual command, id = clientCommandId (ADR-004, criterion 9).
        Table(name: "outbox", columns: [
            .text("type"), .integer("payload_version"), .text("aggregate_type"), .text("aggregate_id"),
            .text("precondition"), .text("client_recorded_at"), .text("payload"),
        ], insertOnly: true),
        Table(name: "sync_rejections", columns: [
            .text("command_type"), .text("aggregate_id"), .text("code"), .text("message"), .text("rejected_at"),
        ], localOnly: true),
        Table(name: "local_meta", columns: [.text("value")], localOnly: true),
        // Proof that iOS accepted a notification request before its time (ADR-018): never synchronized.
        Table(name: "scheduled_notifications", columns: [.text("trigger_at"), .text("accepted_at")], localOnly: true)
    )

    static func open(fileName: String = LocalDatabase.fileName) -> any PowerSyncDatabaseProtocol {
        PowerSyncDatabase(schema: schema, dbFilename: fileName)
    }
}

/// Values kept on this iPhone only.
nonisolated enum LocalMeta {
    static let serverGenerationKey = "server_generation"

    static func serverGeneration(in db: any PowerSyncDatabaseProtocol) async throws -> String? {
        try await db.getOptional(
            sql: "SELECT value FROM local_meta WHERE id = ?",
            parameters: [serverGenerationKey]
        ) { cursor in try cursor.getString(index: 0) }
    }

    static func setServerGeneration(_ value: String, in db: any PowerSyncDatabaseProtocol) async throws {
        try await db.writeTransaction { tx in
            try tx.execute(sql: "DELETE FROM local_meta WHERE id = ?", parameters: [serverGenerationKey])
            try tx.execute(sql: "INSERT INTO local_meta (id, value) VALUES (?, ?)", parameters: [serverGenerationKey, value])
        }
    }
}

nonisolated enum Precondition: Sendable, Equatable {
    case unconditional
    case revision(Int)
    case afterCommand(String)

    var payload: JSONPayload? {
        switch self {
        case .unconditional: nil
        case .revision(let revision): ["kind": "revision", "revision": .int(revision)]
        case .afterCommand(let id): ["kind": "afterCommand", "clientCommandId": .string(id)]
        }
    }
}

/// A manual command written to the queue in the same transaction as its optimistic projection.
nonisolated struct LocalCommand: Sendable {
    nonisolated enum Chaining: Sendable {
        /// Creations never carry a precondition.
        case never
        /// Follows the previous queued command of the same aggregate, if any (offline causality).
        case afterPendingCommand
        /// Sensitive commands (series): the previous queued command, else the revision read.
        case required(revision: Int)
    }

    let id: String
    let type: String
    let aggregateType: String
    let aggregateId: String
    let chaining: Chaining
    let payload: JSONPayload?
    let recordedAt: Date

    init(type: String, aggregateType: String = "task", aggregateId: String, chaining: Chaining = .afterPendingCommand, payload: JSONPayload? = nil) {
        id = UUID().uuidString.lowercased()
        self.type = type
        self.aggregateType = aggregateType
        self.aggregateId = aggregateId
        self.chaining = chaining
        self.payload = payload
        recordedAt = Date()
    }
}

nonisolated enum Outbox {
    /// Must run inside the write transaction that holds the projection.
    static func insert(_ command: LocalCommand, in tx: any Transaction) throws {
        var precondition = Precondition.unconditional
        switch command.chaining {
        case .never:
            break
        case .afterPendingCommand:
            if let previous = try lastPendingCommand(for: command.aggregateId, in: tx) { precondition = .afterCommand(previous) }
        case .required(let revision):
            precondition = try lastPendingCommand(for: command.aggregateId, in: tx).map(Precondition.afterCommand) ?? .revision(revision)
        }
        try tx.execute(
            sql: """
            INSERT INTO outbox (id, type, payload_version, aggregate_type, aggregate_id, precondition, client_recorded_at, payload)
            VALUES (?, ?, 1, ?, ?, ?, ?, ?)
            """,
            parameters: [
                command.id, command.type, command.aggregateType, command.aggregateId,
                try precondition.payload?.encodedText(), Timestamp.format(command.recordedAt),
                try command.payload?.encodedText(),
            ]
        )
    }

    /// The queue entry of an insert-only table is only visible in `ps_crud`.
    static func lastPendingCommand(for aggregateId: String, in tx: any Transaction) throws -> String? {
        try tx.getOptional(
            sql: """
            SELECT json_extract(data, '$.id') FROM ps_crud
            WHERE json_extract(data, '$.type') = 'outbox' AND json_extract(data, '$.data.aggregate_id') = ?
            ORDER BY id DESC LIMIT 1
            """,
            parameters: [aggregateId]
        ) { cursor in try cursor.getString(index: 0) }
    }

    static func pendingSummary(in db: any PowerSyncDatabaseProtocol) async throws -> (count: Int, oldest: Date?) {
        try await db.get(
            sql: """
            SELECT count(*), min(json_extract(data, '$.data.client_recorded_at')) FROM ps_crud
            WHERE json_extract(data, '$.type') = 'outbox'
            """,
            parameters: []
        ) { cursor in (count: try cursor.getInt(index: 0), oldest: Timestamp.parse(cursor.getStringOptional(index: 1))) }
    }
}

nonisolated extension TaskItem {
    static let selectColumns = """
        id, project_id, title, notes, priority, status, completed_at, scheduled_date, scheduled_time, scheduled_time_zone,
        duration_minutes, deadline_date, deadline_time, deadline_time_zone, recurrence, missed_ignored_before,
        deleted_at, revision, created_at
        """

    init(row: any SqlCursor) throws {
        self.init(
            id: try row.getString(name: "id"),
            projectId: try row.getStringOptional(name: "project_id"),
            title: try row.getStringOptional(name: "title") ?? "",
            notes: try row.getStringOptional(name: "notes"),
            priority: Priority(rawValue: try row.getStringOptional(name: "priority") ?? "") ?? .unset,
            isCompleted: try row.getStringOptional(name: "status") == "completed",
            completedAt: Timestamp.parse(try row.getStringOptional(name: "completed_at")),
            schedule: TimeValue(
                date: try row.getStringOptional(name: "scheduled_date"),
                time: try row.getStringOptional(name: "scheduled_time"),
                timeZone: try row.getStringOptional(name: "scheduled_time_zone")
            ),
            durationMinutes: try row.getIntOptional(name: "duration_minutes"),
            deadline: TimeValue(
                date: try row.getStringOptional(name: "deadline_date"),
                time: try row.getStringOptional(name: "deadline_time"),
                timeZone: try row.getStringOptional(name: "deadline_time_zone")
            ),
            recurrence: RecurrenceRule(json: try row.getStringOptional(name: "recurrence")),
            missedIgnoredBefore: CivilDate(try row.getStringOptional(name: "missed_ignored_before")),
            deletedAt: Timestamp.parse(try row.getStringOptional(name: "deleted_at")),
            revision: try row.getIntOptional(name: "revision") ?? 0,
            createdAt: Timestamp.parse(try row.getStringOptional(name: "created_at"))
        )
    }
}
