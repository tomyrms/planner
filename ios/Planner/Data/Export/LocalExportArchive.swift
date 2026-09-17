import Foundation

/// The local extension of exportVersion 1. Unlike a server backup, it describes this iPhone's copy
/// and its unacknowledged intentions. No restore/import is performed by creating this archive.
nonisolated struct LocalExportArchive: Encodable, Sendable {
    let exportVersion = 1
    let localExportVersion = 1
    let taskDetailsVersion = 1
    let exportSource = "iphone"
    let exportedAt: String
    let serverGeneration: String?
    let localState: LocalExportState
    let projects: [JSONPayload]
    let tags: [JSONPayload]
    let taskTags: [JSONPayload]
    let assistantSettings: JSONPayload
    let tasks: [JSONPayload]
    let taskOccurrences: [JSONPayload]
    let reminders: [JSONPayload]
    let conversations: [JSONPayload]
    /// Preserve messages even if their conversation has not reached an incomplete replica yet.
    let unlinkedMessages: [JSONPayload]
    let pendingCommands: [LocalExportCommand]
    let syncRejections: [JSONPayload]
    let drafts: LocalExportDrafts

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

nonisolated struct LocalExportState: Codable, Sendable {
    let capturedAt: String
    let initialSync: String
    let lastSyncedAt: String?
    let connection: String
    let replicatedServerGenerations: [String]
    let warnings: [String]
}

/// Connection state is only an observation made by the UI before reading SQLite, not a promise of
/// server completeness. The generation and all exported rows are read inside the same transaction.
nonisolated struct LocalExportContext: Sendable {
    var hasSynced: Bool?
    var lastSyncedAt: Date?
    var connection: String
    var generationChanged: Bool = false
}

nonisolated struct LocalExportCommand: Codable, Sendable {
    let queueSequence: Int
    let transactionId: Int?
    /// The API command, with the original identifier, version, payload and afterCommand precondition.
    /// Omitted when the stored command cannot be decoded; its exact stored fields remain below.
    let command: JSONPayload?
    /// Only the application's outbox fields. Payload/precondition JSON strings stay byte-for-byte
    /// unchanged, including malformed or future-version data that cannot currently be uploaded.
    let storedCommand: JSONPayload
}

/// Explicit allowlist copied from the two stores. Never encode VoiceDraft: it contains an audio path.
nonisolated struct LocalExportDrafts: Codable, Sendable {
    var assistantConversationId: String? = nil
    var assistantText: String? = nil
    var pendingAssistant: PendingTurn? = nil
    var voice: LocalExportVoiceText? = nil
}

nonisolated struct LocalExportVoiceText: Codable, Sendable {
    let transcriptionId: String
    let conversationId: String?
    let state: String
    let transcript: String?
    let pendingAssistant: PendingTurn?
}
