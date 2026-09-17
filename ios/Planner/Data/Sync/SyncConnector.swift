import Foundation
import PowerSync

/// Why uploads stopped until the user acts (04_Backend/02_API_Contract.md §3.5).
nonisolated enum SyncBlock: Sendable, Equatable {
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

/// One command read back from the insert-only `outbox` table.
nonisolated struct QueuedCommand: Sendable {
    let id: String
    let type: String
    let aggregateId: String
    let json: JSONPayload

    init?(entry: CrudEntry) throws {
        guard entry.table == "outbox", entry.op == .put, let data = entry.opData else { return nil }
        func value(_ key: String) -> String? { data[key] ?? nil }
        guard let type = value("type"), let aggregateType = value("aggregate_type"), let aggregateId = value("aggregate_id"),
              let recordedAt = value("client_recorded_at") else { return nil }
        var command: [String: JSONPayload] = [
            "clientCommandId": .string(entry.id),
            "type": .string(type),
            "payloadVersion": .int(Int(value("payload_version") ?? "") ?? 1),
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
    private let events: AsyncStream<SyncBlock?>.Continuation
    private var block: SyncBlock?
    private var failures = 0
    private var notBefore: Date?

    init(api: APIClient, events: AsyncStream<SyncBlock?>.Continuation) {
        self.api = api
        self.events = events
    }

    func fetchCredentials() async throws -> PowerSyncCredentials? {
        do {
            let token = try await api.syncToken()
            guard let endpoint = token.endpoint else {
                setBlock(.serverMisconfigured)
                return nil
            }
            return PowerSyncCredentials(endpoint: endpoint, token: token.token)
        } catch APIError.unauthorized {
            setBlock(.pairingRequired)
            return nil
        }
    }

    func uploadData(database: any PowerSyncDatabaseProtocol) async throws {
        if let block { throw SyncBlockedError(block: block) }
        if let notBefore, notBefore > Date() { throw SyncDeferredError(until: notBefore) }
        guard let transaction = try await database.getNextCrudTransaction() else { return }
        // Entries of the synced tables are only the optimistic projection: acknowledged without upload.
        let commands = try transaction.crud.compactMap { try QueuedCommand(entry: $0) }
        if !commands.isEmpty {
            guard let generation = try await LocalMeta.serverGeneration(in: database) else {
                setBlock(.generationChanged(nil))
                throw SyncBlockedError(block: .generationChanged(nil))
            }
            let envelope: JSONPayload = [
                "envelopeVersion": 1,
                "serverGeneration": .string(generation),
                "commands": .array(commands.map(\.json)),
            ]
            let response: MutationsResponse
            do {
                response = try await api.uploadMutations(Data(try envelope.encodedText().utf8))
            } catch let error as APIError {
                throw handle(error)
            }
            failures = 0
            notBefore = nil
            try await record(response, commands: commands, in: database)
        }
        // Acknowledged is not applied: rejections stay in sync_rejections until the user handles them.
        try await transaction.complete()
    }

    /// "Réessayer" in Settings, or a new app version.
    func clearBlock() {
        block = nil
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
        let rows = rejected.map { command, rejection in
            [command.id, command.type, command.aggregateId, rejection.code ?? "UNKNOWN", rejection.message ?? "", rejectedAt]
        }
        try await database.writeTransaction { tx in
            for row in rows {
                try tx.execute(sql: "DELETE FROM sync_rejections WHERE id = ?", parameters: [row[0]])
                try tx.execute(
                    sql: "INSERT INTO sync_rejections (id, command_type, aggregate_id, code, message, rejected_at) VALUES (?, ?, ?, ?, ?, ?)",
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
