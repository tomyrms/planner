import Foundation
import PowerSync

nonisolated struct LocalExportRepository: Sendable {
    let db: any PowerSyncDatabaseProtocol

    /// SQL and JSON processing run off the main actor. readTransaction holds one SQLite snapshot:
    /// an acknowledgement or replication cannot move the queue between two of the exported reads.
    @concurrent
    func archive(
        context: LocalExportContext, drafts: LocalExportDrafts = LocalExportDrafts(), at: Date = Date()
    ) async throws -> LocalExportArchive {
        try Task.checkCancellation()
        let exportedAt = Timestamp.format(at)
        let result = try await db.readTransaction { tx in
            let generation = try tx.getOptional(
                sql: "SELECT value FROM local_meta WHERE id = ?", parameters: [LocalMeta.serverGenerationKey]
            ) { cursor in try cursor.getString(index: 0) }
            let replicatedGenerations = try tx.getAll(sql: "SELECT id FROM server_meta ORDER BY id", parameters: []) {
                cursor in try cursor.getString(index: 0)
            }
            let projects = try Self.rows(Self.projectsSQL, in: tx)
            let tags = try Self.rows(Self.tagsSQL, in: tx)
            let taskTags = try Self.rows(Self.taskTagsSQL, in: tx)
            let assistantSettings = try Self.rows(Self.settingsSQL, in: tx).first
                ?? ["autoTags": false, "revision": 1, "createdAt": .null, "updatedAt": .null]
            let tasks = try Self.rows(Self.tasksSQL, in: tx)
            let occurrences = try Self.rows(Self.occurrencesSQL, in: tx)
            let reminders = try Self.rows(Self.remindersSQL, in: tx)
            let conversations = try Self.rows(Self.conversationsSQL, in: tx)
            let messages = try Self.rows(Self.messagesSQL, in: tx)
            let commands = try tx.getAll(sql: Self.commandsSQL, parameters: []) { cursor in
                let stored = try JSONPayload.decode(cursor.getString(index: 2))
                return LocalExportCommand(
                    queueSequence: try cursor.getInt(index: 0), transactionId: cursor.getIntOptional(index: 1),
                    command: Self.apiCommand(stored), storedCommand: stored
                )
            }
            let rejections = try Self.rows(Self.rejectionsSQL, in: tx)
            let conversationIds = Set(conversations.compactMap { Self.string("id", in: $0) })
            let grouped = Dictionary(grouping: messages) { Self.string("conversationId", in: $0) ?? "" }
            let withMessages = conversations.map { conversation -> JSONPayload in
                guard case .object(var fields) = conversation, let id = Self.string("id", in: conversation) else { return conversation }
                fields["messages"] = .array(grouped[id] ?? [])
                return .object(fields)
            }
            let unlinked = messages.filter { !conversationIds.contains(Self.string("conversationId", in: $0) ?? "") }
            var warnings = ["LOCAL_SNAPSHOT_ONLY", "AUDIO_EXCLUDED", "DELETED_REMINDERS_NOT_REPLICATED", "DRAFTS_CAPTURED_SEPARATELY"]
            if context.hasSynced != true { warnings.append(context.hasSynced == false ? "INITIAL_SYNC_INCOMPLETE" : "INITIAL_SYNC_UNKNOWN") }
            let generationMismatch = generation.map { seen in
                replicatedGenerations.contains { $0.caseInsensitiveCompare(seen) != .orderedSame }
            } ?? false
            if context.generationChanged || generationMismatch {
                warnings.append("SERVER_GENERATION_CHANGED")
            }
            if generation == nil { warnings.append("LOCAL_GENERATION_UNKNOWN") }
            if commands.contains(where: { $0.command == nil }) { warnings.append("COMMAND_REQUIRES_RECOVERY") }
            if !unlinked.isEmpty { warnings.append("MESSAGES_WITHOUT_LOCAL_CONVERSATION") }
            return LocalExportArchive(
                exportedAt: exportedAt, serverGeneration: generation,
                localState: LocalExportState(
                    capturedAt: exportedAt, initialSync: context.hasSynced.map { $0 ? "completed" : "incomplete" } ?? "unknown",
                    lastSyncedAt: context.lastSyncedAt.map(Timestamp.format), connection: context.connection,
                    replicatedServerGenerations: replicatedGenerations, warnings: warnings
                ),
                projects: projects, tags: tags, taskTags: taskTags, assistantSettings: assistantSettings,
                tasks: tasks, taskOccurrences: occurrences, reminders: reminders,
                conversations: withMessages, unlinkedMessages: unlinked, pendingCommands: commands,
                syncRejections: rejections, drafts: drafts
            )
        }
        try Task.checkCancellation()
        return result
    }

    @concurrent
    func data(context: LocalExportContext, drafts: LocalExportDrafts = LocalExportDrafts(), at: Date = Date()) async throws -> Data {
        try await archive(context: context, drafts: drafts, at: at).encoded()
    }

    private static func rows(_ sql: String, in tx: any Transaction) throws -> [JSONPayload] {
        try tx.getAll(sql: sql, parameters: []) { cursor in try JSONPayload.decode(cursor.getString(index: 0)) }
    }

    private static func string(_ key: String, in value: JSONPayload) -> String? {
        guard case .object(let fields) = value, case .string(let text) = fields[key] else { return nil }
        return text
    }

    private static func apiCommand(_ stored: JSONPayload) -> JSONPayload? {
        guard case .object(let fields) = stored,
              let id = string("id", in: stored), let type = string("type", in: stored),
              let aggregateType = string("aggregate_type", in: stored), let aggregateId = string("aggregate_id", in: stored),
              let recordedAt = string("client_recorded_at", in: stored) else { return nil }
        let version: Int?
        switch fields["payload_version"] {
        case .int(let number): version = number
        case .string(let text): version = Int(text)
        default: version = nil
        }
        guard let version else { return nil }
        var command: [String: JSONPayload] = [
            "clientCommandId": .string(id), "type": .string(type), "payloadVersion": .int(version),
            "aggregate": ["type": .string(aggregateType), "id": .string(aggregateId)],
            "clientRecordedAt": .string(recordedAt),
        ]
        for (column, key) in [("payload", "payload"), ("precondition", "precondition")] {
            switch fields[column] {
            case .none, .null: break
            case .string(let text):
                guard let decoded = try? JSONPayload.decode(text) else { return nil }
                command[key] = decoded
            default: return nil
            }
        }
        return .object(command)
    }

    // Explicit field lists: no database dump, credentials, internal sync state, search cache, audio,
    // provider metadata or assistant plans. Civil dates and original IANA zones remain strings.
    private static let projectsSQL = """
        SELECT json_object('id', id, 'name', name, 'colorKey', color_key, 'sortOrder', sort_order,
          'archivedAt', archived_at, 'deletedAt', deleted_at, 'revision', revision, 'createdAt', created_at, 'updatedAt', updated_at)
        FROM projects ORDER BY created_at, id
        """
    private static let tasksSQL = """
        SELECT json_object('id', id, 'projectId', project_id, 'title', title, 'notes', notes, 'priority', priority,
          'subtasks', CASE WHEN subtasks IS NULL THEN json('[]') WHEN json_valid(subtasks) THEN json(subtasks) ELSE subtasks END,
          'status', status, 'completedAt', completed_at,
          'schedule', CASE WHEN scheduled_date IS NULL THEN NULL WHEN scheduled_time IS NULL THEN json_object('date', scheduled_date) ELSE json_object('date', scheduled_date,
            'time', substr(scheduled_time, 1, 5), 'timeZone', scheduled_time_zone) END,
          'durationMinutes', duration_minutes,
          'deadline', CASE WHEN deadline_date IS NULL THEN NULL WHEN deadline_time IS NULL THEN json_object('date', deadline_date) ELSE json_object('date', deadline_date,
            'time', substr(deadline_time, 1, 5), 'timeZone', deadline_time_zone) END,
          'recurrence', CASE WHEN recurrence IS NULL THEN NULL WHEN json_valid(recurrence) THEN json(recurrence) ELSE recurrence END,
          'missedIgnoredBefore', missed_ignored_before, 'deletedAt', deleted_at, 'revision', revision,
          'createdAt', created_at, 'updatedAt', updated_at)
        FROM tasks ORDER BY created_at, id
        """
    private static let tagsSQL = """
        SELECT json_object('id', id, 'name', name, 'deletedAt', deleted_at, 'revision', revision,
          'createdAt', created_at, 'updatedAt', updated_at)
        FROM tags ORDER BY name, id
        """
    private static let taskTagsSQL = """
        SELECT json_object('id', id, 'taskId', task_id, 'tagId', tag_id, 'deletedAt', deleted_at,
          'createdAt', created_at, 'updatedAt', updated_at)
        FROM task_tags ORDER BY task_id, tag_id
        """
    private static let settingsSQL = """
        SELECT json_object('autoTags', json(CASE WHEN auto_tags = 1 THEN 'true' ELSE 'false' END),
          'revision', revision, 'createdAt', created_at, 'updatedAt', updated_at)
        FROM user_settings ORDER BY id
        """
    private static let occurrencesSQL = """
        SELECT json_object('id', id, 'taskId', task_id, 'occurrenceKey', occurrence_key, 'status', status,
          'completedAt', completed_at, 'override', CASE WHEN override_date IS NULL THEN NULL WHEN override_time IS NULL THEN json_object('date', override_date) ELSE json_object(
            'date', override_date, 'time', substr(override_time, 1, 5), 'timeZone', override_time_zone) END,
          'successorOccurrenceKey', successor_occurrence_key, 'createdAt', created_at, 'updatedAt', updated_at)
        FROM task_occurrences ORDER BY task_id, occurrence_key, id
        """
    private static let remindersSQL = """
        SELECT json_object('id', id, 'taskId', task_id, 'occurrenceKey', occurrence_key, 'kind', kind,
          'offsetMinutes', offset_minutes, 'localTime', substr(local_time, 1, 5),
          'absolute', CASE WHEN absolute_date IS NULL THEN NULL ELSE json_object('date', absolute_date,
            'time', substr(absolute_time, 1, 5), 'timeZone', absolute_time_zone) END,
          'state', state, 'createdAt', created_at, 'updatedAt', updated_at)
        FROM reminders ORDER BY task_id, id
        """
    private static let conversationsSQL = """
        SELECT json_object('id', id, 'title', title, 'createdAt', created_at, 'updatedAt', updated_at)
        FROM conversations ORDER BY created_at, id
        """
    private static let messagesSQL = """
        SELECT json_object('id', id, 'conversationId', conversation_id, 'seq', seq, 'role', role, 'kind', kind,
          'text', text, 'originalTranscript', original_transcript, 'transcriptionId', transcription_id,
          'revisesMessageId', revises_message_id, 'createdAt', created_at)
        FROM messages ORDER BY conversation_id, seq, id
        """
    private static let commandsSQL = """
        SELECT id, tx_id, json_object('id', json_extract(data, '$.id'),
          'type', json_extract(data, '$.data.type'), 'payload_version', json_extract(data, '$.data.payload_version'),
          'aggregate_type', json_extract(data, '$.data.aggregate_type'), 'aggregate_id', json_extract(data, '$.data.aggregate_id'),
          'precondition', json_extract(data, '$.data.precondition'), 'client_recorded_at', json_extract(data, '$.data.client_recorded_at'),
          'payload', json_extract(data, '$.data.payload'))
        FROM ps_crud WHERE json_extract(data, '$.type') = 'outbox' ORDER BY id
        """
    private static let rejectionsSQL = """
        SELECT json_object('id', id, 'commandType', command_type, 'aggregateId', aggregate_id,
          'code', code, 'message', message, 'rejectedAt', rejected_at,
          'command', CASE WHEN json_valid(command_json) THEN json(command_json) ELSE NULL END,
          'storedCommand', command_json)
        FROM sync_rejections ORDER BY rejected_at, id
        """
}
