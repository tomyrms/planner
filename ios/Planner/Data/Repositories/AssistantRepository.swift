import Foundation
import PowerSync

nonisolated struct ConversationSummary: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let updatedAt: Date?
}

nonisolated struct ThreadMessage: Identifiable, Hashable, Sendable {
    let id: String
    let seq: Int
    let role: String
    let kind: String
    let text: String
    let originalTranscript: String?
    let turnId: String?
    let createdAt: Date?

    var isUser: Bool { role == "user" }
}

/// What a turn allows now, from the replicated turn, proposal and action rows.
nonisolated struct TurnControls: Hashable, Sendable {
    let turnId: String
    let status: String
    let errorCode: String?
    let proposalId: String?
    let planHash: String?
    let proposalState: String?
    let proposalExpiresAt: Date?
    /// First undoable action of the turn's group, if its window is still open.
    let undoActionId: String?
    let undoState: String?
    let undoExpiresAt: Date?
    let taskIds: [String]

    var canConfirm: Bool {
        proposalState == "pending" && (proposalExpiresAt.map { $0 > Date() } ?? false)
    }

    var canUndo: Bool {
        undoActionId != nil && undoState == "available" && (undoExpiresAt.map { $0 > Date() } ?? false)
    }
}

/// Assistant history (read-only replica) and the unsent state of this iPhone.
nonisolated struct AssistantRepository: Sendable {
    let db: any PowerSyncDatabaseProtocol

    func observeConversations() throws -> AsyncThrowingStream<[ConversationSummary], any Error> {
        try db.watch(
            sql: "SELECT id, title, updated_at FROM conversations ORDER BY updated_at DESC LIMIT 200",
            parameters: []
        ) { cursor in
            ConversationSummary(
                id: try cursor.getString(name: "id"),
                title: try cursor.getStringOptional(name: "title") ?? "Conversation",
                updatedAt: Timestamp.parse(try cursor.getStringOptional(name: "updated_at"))
            )
        }
    }

    func observeMessages(conversationId: String) throws -> AsyncThrowingStream<[ThreadMessage], any Error> {
        try db.watch(
            sql: """
            SELECT id, seq, role, kind, text, original_transcript, turn_id, created_at FROM messages
            WHERE conversation_id = ? ORDER BY seq
            """,
            parameters: [conversationId]
        ) { cursor in
            ThreadMessage(
                id: try cursor.getString(name: "id"),
                seq: try cursor.getIntOptional(name: "seq") ?? 0,
                role: try cursor.getStringOptional(name: "role") ?? "assistant",
                kind: try cursor.getStringOptional(name: "kind") ?? "text",
                text: try cursor.getStringOptional(name: "text") ?? "",
                originalTranscript: try cursor.getStringOptional(name: "original_transcript"),
                turnId: try cursor.getStringOptional(name: "turn_id"),
                createdAt: Timestamp.parse(try cursor.getStringOptional(name: "created_at"))
            )
        }
    }

    func observeTurns(conversationId: String) throws -> AsyncThrowingStream<[TurnControls], any Error> {
        try db.watch(
            sql: """
            SELECT t.id, t.status, t.error_code,
                   p.id AS proposal_id, p.plan_hash, p.state AS proposal_state, p.expires_at AS proposal_expires_at,
                   (SELECT a.id FROM ai_actions a WHERE a.turn_id = t.id AND a.undo_of_action_id IS NULL
                      ORDER BY a.undo_state = 'available' DESC, a.plan_index LIMIT 1) AS undo_action_id,
                   (SELECT a.undo_state FROM ai_actions a WHERE a.turn_id = t.id AND a.undo_of_action_id IS NULL
                      ORDER BY a.undo_state = 'available' DESC, a.plan_index LIMIT 1) AS undo_state,
                   (SELECT a.undo_expires_at FROM ai_actions a WHERE a.turn_id = t.id AND a.undo_of_action_id IS NULL
                      ORDER BY a.undo_state = 'available' DESC, a.plan_index LIMIT 1) AS undo_expires_at,
                   (SELECT group_concat(DISTINCT a.aggregate_id) FROM ai_actions a
                      WHERE a.turn_id = t.id AND a.undo_of_action_id IS NULL AND a.aggregate_type = 'task') AS task_ids
            FROM assistant_turns t
            LEFT JOIN assistant_proposals p ON p.turn_id = t.id
            WHERE t.conversation_id = ?
            """,
            parameters: [conversationId]
        ) { cursor in
            TurnControls(
                turnId: try cursor.getString(name: "id"),
                status: try cursor.getStringOptional(name: "status") ?? "received",
                errorCode: try cursor.getStringOptional(name: "error_code"),
                proposalId: try cursor.getStringOptional(name: "proposal_id"),
                planHash: try cursor.getStringOptional(name: "plan_hash"),
                proposalState: try cursor.getStringOptional(name: "proposal_state"),
                proposalExpiresAt: Timestamp.parse(try cursor.getStringOptional(name: "proposal_expires_at")),
                undoActionId: try cursor.getStringOptional(name: "undo_action_id"),
                undoState: try cursor.getStringOptional(name: "undo_state"),
                undoExpiresAt: Timestamp.parse(try cursor.getStringOptional(name: "undo_expires_at")),
                taskIds: (try cursor.getStringOptional(name: "task_ids") ?? "").split(separator: ",").map(String.init)
            )
        }
    }

    /// Changes made by the assistant to one task, newest first ("Modifié par l'assistant").
    func observeActions(taskId: String) throws -> AsyncThrowingStream<[AssistantChange], any Error> {
        try db.watch(
            sql: """
            SELECT a.id, a.command_type, a.undo_state, a.undo_expires_at, a.undo_of_action_id, a.created_at, t.conversation_id
            FROM ai_actions a LEFT JOIN assistant_turns t ON t.id = a.turn_id
            WHERE a.aggregate_id = ? ORDER BY a.created_at DESC LIMIT 50
            """,
            parameters: [taskId]
        ) { cursor in
            AssistantChange(
                id: try cursor.getString(name: "id"),
                commandType: try cursor.getStringOptional(name: "command_type") ?? "",
                undoState: try cursor.getStringOptional(name: "undo_state") ?? "not_undoable",
                undoExpiresAt: Timestamp.parse(try cursor.getStringOptional(name: "undo_expires_at")),
                isUndo: try cursor.getStringOptional(name: "undo_of_action_id") != nil,
                createdAt: Timestamp.parse(try cursor.getStringOptional(name: "created_at")),
                conversationId: try cursor.getStringOptional(name: "conversation_id")
            )
        }
    }

    /// Aggregates with manual commands still waiting in the queue (sent as `unsyncedAggregateIds`).
    func pendingAggregateIds() async throws -> [String] {
        try await db.getAll(
            sql: """
            SELECT DISTINCT json_extract(data, '$.data.aggregate_id') FROM ps_crud
            WHERE json_extract(data, '$.type') = 'outbox'
            """,
            parameters: []
        ) { cursor in try cursor.getString(index: 0) }
    }
}

nonisolated struct AssistantChange: Identifiable, Hashable, Sendable {
    let id: String
    let commandType: String
    let undoState: String
    let undoExpiresAt: Date?
    let isUndo: Bool
    let createdAt: Date?
    let conversationId: String?

    var canUndo: Bool {
        !isUndo && undoState == "available" && (undoExpiresAt.map { $0 > Date() } ?? false)
    }
}
