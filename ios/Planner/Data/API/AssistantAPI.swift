import Foundation

/// Snapshot of a turn (04_Backend/02_API_Contract.md §4.2), decoded loosely: unknown fields are ignored.
nonisolated struct TurnSnapshot: Decodable, Sendable, Equatable {
    nonisolated struct Message: Decodable, Sendable, Equatable {
        let id: String
        let seq: Int
        let role: String
        let kind: String
        let text: String
    }

    nonisolated struct Proposal: Decodable, Sendable, Equatable {
        let proposalId: String
        let state: String
        let planHash: String
        let expiresAt: String
    }

    nonisolated struct Clarification: Decodable, Sendable, Equatable {
        let question: String
        let options: [String]
    }

    nonisolated struct Undo: Decodable, Sendable, Equatable {
        let actionId: String
        let state: String
        let expiresAt: String?
    }

    nonisolated struct Result: Decodable, Sendable, Equatable {
        let actionId: String
        let commandType: String
        let aggregateType: String
        let aggregateId: String
        let title: String?
    }

    nonisolated struct Failure: Decodable, Sendable, Equatable {
        let code: String
    }

    let turnId: String
    let conversationId: String
    let status: String
    let messages: [Message]
    let proposal: Proposal?
    let results: [Result]
    let undo: Undo?
    let clarification: Clarification?
    let error: Failure?

    var isFinished: Bool {
        ["completed", "failed", "cancelled", "awaiting_confirmation", "awaiting_clarification"].contains(status)
    }
}

nonisolated struct ConfirmResponse: Decodable, Sendable {
    let proposalId: String
    let state: String
    let message: String?
}

nonisolated struct UndoResponse: Decodable, Sendable {
    let actionId: String
    let outcome: String
    let message: String?
}

nonisolated struct TurnRequest: Encodable, Sendable {
    nonisolated struct Message: Encodable, Sendable {
        let id: String
        let text: String
        let transcriptionId: String?
        let revisesMessageId: String?

        // Explicit nulls: the server's schema requires the keys.
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(text, forKey: .text)
            try container.encode(transcriptionId, forKey: .transcriptionId)
            try container.encode(revisesMessageId, forKey: .revisesMessageId)
        }

        private nonisolated enum CodingKeys: String, CodingKey {
            case id, text, transcriptionId, revisesMessageId
        }
    }

    let turnId: String
    let conversationId: String
    let message: Message
    let referenceInstant: String
    let timeZone: String
    let unsyncedAggregateIds: [String]

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(turnId, forKey: .turnId)
        try container.encode(conversationId, forKey: .conversationId)
        try container.encode(message, forKey: .message)
        try container.encode(referenceInstant, forKey: .referenceInstant)
        try container.encode(timeZone, forKey: .timeZone)
        try container.encode(unsyncedAggregateIds, forKey: .unsyncedAggregateIds)
        try container.encodeNil(forKey: .calendarContext)
    }

    private nonisolated enum CodingKeys: String, CodingKey {
        case turnId, conversationId, message, referenceInstant, timeZone, unsyncedAggregateIds, calendarContext
    }
}

private nonisolated struct ConfirmBody: Encodable, Sendable { let planHash: String }
private nonisolated struct UndoBody: Encodable, Sendable { let undoRequestId: String }

/// Assistant routes (§4). Every call is authenticated; nothing here is queued for later.
extension APIClient {
    func submitTurn(_ request: TurnRequest) async throws -> TurnSnapshot {
        try await call("POST", "api/v1/assistant/turns", body: request, expecting: 200, timeout: 100)
    }

    func turn(_ id: String) async throws -> TurnSnapshot {
        try await call("GET", "api/v1/assistant/turns/\(id)", expecting: 200)
    }

    func cancelTurn(_ id: String) async throws -> TurnSnapshot {
        try await call("POST", "api/v1/assistant/turns/\(id)/cancel", expecting: 200)
    }

    func confirmProposal(_ id: String, planHash: String) async throws -> ConfirmResponse {
        try await call("POST", "api/v1/assistant/proposals/\(id)/confirm", body: ConfirmBody(planHash: planHash), expecting: 200)
    }

    func rejectProposal(_ id: String) async throws {
        let _: ConfirmResponse = try await call("POST", "api/v1/assistant/proposals/\(id)/reject", expecting: 200)
    }

    func undoAction(_ id: String, requestId: String) async throws -> UndoResponse {
        try await call("POST", "api/v1/assistant/actions/\(id)/undo", body: UndoBody(undoRequestId: requestId), expecting: 200)
    }

    func deleteConversation(_ id: String) async throws {
        try await callWithoutBody("DELETE", "api/v1/conversations/\(id)", expecting: 204)
    }

    func deleteMessage(_ id: String) async throws {
        try await callWithoutBody("DELETE", "api/v1/messages/\(id)", expecting: 204)
    }
}
