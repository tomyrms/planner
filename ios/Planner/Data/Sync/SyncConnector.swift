import Foundation
import PowerSync

/// Why uploads stopped until the user acts (04_Backend/02_API_Contract.md §3.5).
nonisolated enum SyncBlock: Codable, Sendable, Equatable {
    /// The server was restored from a backup: keep the queue, export, then recover.
    case generationChanged(String?)
    /// 400, 403, 404, 413 or an unknown payload: the queue is kept, nothing is dropped.
    case actionRequired(status: Int, code: String?)
    case updateRequired(minimumVersion: String?)
    /// Refresh impossible (revoked device, expired session).
    case pairingRequired
    /// The server gave no sync address (PUBLIC_SYNC_URL).
    case serverMisconfigured
}

nonisolated struct SyncBlockedError: Error {
    let block: SyncBlock
}

nonisolated struct SyncDeferredError: Error {
    let until: Date
}

nonisolated struct AssistantSettingsPendingError: Error, Sendable {
    static let message = "Le réglage de l’assistant attend la synchronisation. Réessayez dès qu’elle est terminée ; votre message est conservé."
}

/// One command read back from the insert-only `outbox` table.
nonisolated struct QueuedCommand: Sendable {
    let id: String
    let type: String
    let aggregateId: String
    let json: JSONPayload

    init?(entry: CrudEntry) throws {
        guard entry.table == "outbox" else { return nil }
        guard entry.op == .put, let data = entry.opData else { throw APIError.invalidResponse }
        func value(_ key: String) -> String? { data[key] ?? nil }
        guard let type = value("type"), let aggregateType = value("aggregate_type"), let aggregateId = value("aggregate_id"),
              let recordedAt = value("client_recorded_at"),
              let version = value("payload_version").flatMap(Int.init), version > 0 else { throw APIError.invalidResponse }
        var command: [String: JSONPayload] = [
            "clientCommandId": .string(entry.id),
            "type": .string(type),
            "payloadVersion": .int(version),
            "aggregate": ["type": .string(aggregateType), "id": .string(aggregateId)],
            "clientRecordedAt": .string(recordedAt),
        ]
        if let precondition = value("precondition") { command["precondition"] = try JSONPayload.decode(precondition) }
        if let payload = value("payload") { command["payload"] = try JSONPayload.decode(payload) }
        self.id = entry.id
        self.type = type
        self.aggregateId = aggregateId
        self.json = .object(command)
    }
}

/// PowerSync connector: sync tokens from the API, and the upload of the command queue in order.
actor SyncConnector: PowerSyncBackendConnectorProtocol {
    private let api: APIClient
    private let database: any PowerSyncDatabaseProtocol
    private let events: AsyncStream<SyncBlock?>.Continuation
    private var block: SyncBlock?
    private var failures = 0
    private var notBefore: Date?
    private var identityVerified = false

    init(api: APIClient, database: any PowerSyncDatabaseProtocol, events: AsyncStream<SyncBlock?>.Continuation) {
        self.api = api
        self.database = database
        self.events = events
    }

    func fetchCredentials() async throws -> PowerSyncCredentials? {
        do {
            try await checkRecoveryBlock()
            let token = try await api.syncToken()
            try await validateIdentity(token)
            try await checkRecoveryBlock()
            guard let endpoint = token.endpoint else {
                setBlock(.serverMisconfigured)
                return nil
            }
            return PowerSyncCredentials(endpoint: endpoint, token: token.token)
        } catch APIError.unauthorized(code: "SESSION_REPLACED") {
            throw CancellationError()
        } catch APIError.unauthorized {
            try await requireRecovery(.pairingRequired)
            return nil
        }
    }

    /// The token is authenticated before any connection can replace the local replica.
    private func validateIdentity(_ token: SyncTokenResponse) async throws {
        let generation = try await LocalMeta.serverGeneration(in: database)
        guard generation?.caseInsensitiveCompare(token.serverGeneration) == .orderedSame else {
            try await requireRecovery(.generationChanged(token.serverGeneration))
            throw SyncBlockedError(block: .generationChanged(token.serverGeneration))
        }
        let owner = try await LocalMeta.ownerUserId(in: database)
        if let owner {
            guard owner.caseInsensitiveCompare(token.userId) == .orderedSame else {
                try await requireRecovery(.pairingRequired)
                throw SyncBlockedError(block: .pairingRequired)
            }
        } else {
            // Upgrade only from the same device's still-valid refresh session. The recovery flow
            // never connects a freshly paired identity to an unowned existing database.
            guard await api.establishedUserId()?.caseInsensitiveCompare(token.userId) == .orderedSame else {
                try await requireRecovery(.pairingRequired)
                throw SyncBlockedError(block: .pairingRequired)
            }
            try await LocalMeta.setOwnerUserId(token.userId, in: database)
        }
        identityVerified = true
    }

    private func checkRecoveryBlock() async throws {
        if let block { throw SyncBlockedError(block: block) }
        if let saved = try await LocalMeta.recoveryBlock(in: database) {
            setBlock(saved)
            throw SyncBlockedError(block: saved)
        }
    }

    func requireRecovery(_ reason: SyncBlock) async throws {
        identityVerified = false
        setBlock(reason)
        try await LocalMeta.setRecoveryBlock(reason, in: database)
    }

    /// Remote assistant actions must also honor the identity/generation barrier. The sync-token
    /// read is outside the assistant API, so it cannot recurse into its own validation callback.
    func installOnlineActionGuard() async {
        await api.setOnlineActionValidator { [weak self] path in
            guard let self else { throw CancellationError() }
            try await self.verifyOnlineIdentity()
            if path == "api/v1/assistant/turns" || (path.hasPrefix("api/v1/assistant/proposals/") && path.hasSuffix("/confirm")) {
                try await self.verifyAssistantSettingsSynced()
            }
        }
    }

    private func verifyAssistantSettingsSynced() async throws {
        let pending = try await database.get(
            sql: """
            SELECT count(*) FROM ps_crud
            WHERE json_extract(data, '$.type') = 'outbox'
              AND json_extract(data, '$.data.type') = 'settings.patch'
            """, parameters: []
        ) { try $0.getInt(index: 0) }
        // This transient guard must not disconnect sync: it needs to upload this preference.
        if pending > 0 { throw AssistantSettingsPendingError() }
    }

    func verifyOnlineIdentity() async throws {
        try await checkRecoveryBlock()
        do {
            let token = try await api.syncToken()
            try await validateIdentity(token)
            try await checkRecoveryBlock()
        } catch APIError.unauthorized(code: "SESSION_REPLACED") {
            throw CancellationError()
        } catch APIError.unauthorized {
            try await requireRecovery(.pairingRequired)
            throw SyncBlockedError(block: .pairingRequired)
        }
    }

    func uploadData(database: any PowerSyncDatabaseProtocol) async throws {
        try await checkRecoveryBlock()
        if !identityVerified {
            try await verifyOnlineIdentity()
        }
        if let notBefore, notBefore > Date() { throw SyncDeferredError(until: notBefore) }
        guard let transaction = try await database.getNextCrudTransaction() else { return }
        // Entries of the synced tables are only the optimistic projection: acknowledged without upload.
        let commands: [QueuedCommand]
        do {
            commands = try transaction.crud.compactMap { try QueuedCommand(entry: $0) }
        } catch {
            let reason = SyncBlock.actionRequired(status: 0, code: "LOCAL_COMMAND_INVALID")
            setBlock(reason)
            throw SyncBlockedError(block: reason)
        }
        if !commands.isEmpty {
            guard let generation = try await LocalMeta.serverGeneration(in: database) else {
                try await requireRecovery(.generationChanged(nil))
                throw SyncBlockedError(block: .generationChanged(nil))
            }
            // A full checklist edit can exceed the HTTP envelope's 100-command limit. Keep one
            // atomic local transaction, and replay the same IDs if a later batch fails.
            for start in stride(from: 0, to: commands.count, by: 100) {
                try await checkRecoveryBlock()
                let batch = Array(commands[start..<min(start + 100, commands.count)])
                try await uploadBatch(batch, generation: generation, in: database)
            }
        }
        // Acknowledged is not applied: rejections stay in sync_rejections until the user handles them.
        try await checkRecoveryBlock()
        try await transaction.complete()
    }

    private func uploadBatch(_ commands: [QueuedCommand], generation: String, in database: any PowerSyncDatabaseProtocol) async throws {
        let envelope: JSONPayload = [
            "envelopeVersion": 1,
            "serverGeneration": .string(generation),
            "commands": .array(commands.map(\.json)),
        ]
        let response: MutationsResponse
        do {
            response = try await api.uploadMutations(Data(try envelope.encodedText().utf8))
        } catch let error as APIError {
            if error == .unauthorized(code: "SESSION_REPLACED") { throw CancellationError() }
            if case .unauthorized = error { try await requireRecovery(.pairingRequired) }
            if case .http(409, .some("SERVER_GENERATION_CHANGED"), _, let generation, _, _) = error {
                try await requireRecovery(.generationChanged(generation))
            }
            throw handle(error)
        }
        guard response.serverGeneration.caseInsensitiveCompare(generation) == .orderedSame else {
            try await requireRecovery(.generationChanged(response.serverGeneration))
            throw SyncBlockedError(block: .generationChanged(response.serverGeneration))
        }
        // An incomplete or unknown receipt never acknowledges the local intent.
        let expected = Set(commands.map { $0.id.lowercased() })
        let received = Set(response.results.map { $0.clientCommandId.lowercased() })
        guard response.results.count == commands.count, expected == received,
              response.results.allSatisfy({ result in
                  switch result.outcome {
                  case "applied", "rejected": true
                  case "duplicate": result.original.map { ["applied", "rejected"].contains($0.outcome) } ?? false
                  default: false
                  }
              }) else { throw handle(.invalidResponse) }
        failures = 0
        notBefore = nil
        try await checkRecoveryBlock()
        try await record(response, commands: commands, in: database)
    }

    /// "Réessayer" in Settings, or a new app version.
    func clearBlock() {
        block = nil
        identityVerified = false
        failures = 0
        notBefore = nil
        events.yield(nil)
    }

    private func record(_ response: MutationsResponse, commands: [QueuedCommand], in database: any PowerSyncDatabaseProtocol) async throws {
        let rejected: [(QueuedCommand, MutationOutcome)] = response.results.compactMap { result in
            guard let rejection = result.rejection,
                  let command = commands.first(where: { $0.id.caseInsensitiveCompare(result.clientCommandId) == .orderedSame })
            else { return nil }
            return (command, rejection)
        }
        guard !rejected.isEmpty else { return }
        let rejectedAt = Timestamp.format(Date())
        let rows = try rejected.map { command, rejection in
            [command.id, command.type, command.aggregateId, rejection.code ?? "UNKNOWN", rejection.message ?? "", rejectedAt, try command.json.encodedText()]
        }
        try await database.writeTransaction { tx in
            for row in rows {
                try tx.execute(sql: "DELETE FROM sync_rejections WHERE id = ?", parameters: [row[0]])
                try tx.execute(
                    sql: "INSERT INTO sync_rejections (id, command_type, aggregate_id, code, message, rejected_at, command_json) VALUES (?, ?, ?, ?, ?, ?, ?)",
                    parameters: row.map { $0 as Sendable? }
                )
            }
        }
    }

    private func handle(_ error: APIError) -> any Error {
        switch error {
        case .unauthorized:
            setBlock(.pairingRequired)
        case .http(409, .some("SERVER_GENERATION_CHANGED"), _, let generation, _, _):
            // No complete(), no purge: the queue waits for the recovery (03_iOS/02_Local_Data_Sync.md).
            setBlock(.generationChanged(generation))
        case .http(426, _, _, _, let minimumVersion, _):
            setBlock(.updateRequired(minimumVersion: minimumVersion))
        case .http(429, _, let retryAfter, _, _, _):
            deferUploads(retryAfter ?? backoff())
        case .http(let status, _, _, _, _, _) where status >= 500 || status == 408:
            deferUploads(backoff())
        case .http(let status, let code, _, _, _, _):
            setBlock(.actionRequired(status: status, code: code))
        case .transport, .invalidResponse:
            deferUploads(backoff())
        }
        return error
    }

    /// Exponential backoff with jitter; PowerSync calls again every few seconds and finds it deferred.
    private func backoff() -> TimeInterval {
        failures += 1
        let base = min(300, 5 * pow(2, Double(min(failures, 8) - 1)))
        return base * Double.random(in: 0.5...1)
    }

    private func deferUploads(_ delay: TimeInterval) {
        notBefore = Date().addingTimeInterval(delay)
    }

    private func setBlock(_ newBlock: SyncBlock) {
        guard block != newBlock else { return }
        block = newBlock
        events.yield(newBlock)
    }
}
