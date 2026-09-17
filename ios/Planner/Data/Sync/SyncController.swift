import Foundation
import Observation
import PowerSync

/// Starts and stops the sync engine and reports what needs the user (03_iOS/02_Local_Data_Sync.md).
@Observable
final class SyncController {
    private(set) var block: SyncBlock?
    let db: any PowerSyncDatabaseProtocol
    private let connector: SyncConnector
    @ObservationIgnored private var listeners: [Task<Void, Never>] = []
    @ObservationIgnored private var disconnection: Task<Void, Never>?

    init(db: any PowerSyncDatabaseProtocol, api: APIClient) {
        self.db = db
        let (stream, continuation) = AsyncStream.makeStream(of: SyncBlock?.self)
        connector = SyncConnector(api: api, database: db, events: continuation)
        listeners.append(Task { [weak self] in
            for await block in stream {
                guard !Task.isCancelled else { return }
                self?.apply(block)
            }
        })
    }

    // Engine state for the views, which never see PowerSync types (observation passes through).
    var isConnected: Bool { status.connected }
    var isConnecting: Bool { status.connecting }
    var isTransferring: Bool { status.uploading || status.downloading }
    var lastSyncedAt: Date? { status.lastSyncedAt }
    /// `nil` while the first sync state is unknown.
    var hasSynced: Bool? { status.hasSynced }

    private var status: ObservableSyncStatus {
        db.currentStatus.observable
    }

    func start() async {
        await connector.installOnlineActionGuard()
        watchServerGeneration()
        do {
            if let saved = try await LocalMeta.recoveryBlock(in: db) {
                apply(saved)
                return
            }
            try await db.connect(connector: connector, crudThrottle: 1, retryDelay: 5)
        } catch {
            apply(.actionRequired(status: 0, code: "CONNECT_FAILED"))
        }
    }

    /// A connect() return does not prove that asynchronous credential validation has finished.
    func validateBeforeOnlineActions() async -> Bool {
        do {
            try await connector.verifyOnlineIdentity()
            return true
        } catch let error as SyncBlockedError {
            apply(error.block)
            return false
        } catch { return false }
    }

    func stop() async {
        let stopping = listeners
        for listener in stopping { listener.cancel() }
        listeners.removeAll()
        for listener in stopping { await listener.value }
        disconnection?.cancel()
        disconnection = nil
        try? await db.disconnect()
    }

    /// Recovery first suspends uploads and replication, without clearing any local rows.
    func suspendForRecovery() async throws {
        let reason: SyncBlock = block ?? .pairingRequired
        try await connector.requireRecovery(reason)
        block = reason
        let stopping = listeners
        for listener in stopping { listener.cancel() }
        listeners.removeAll()
        for listener in stopping { await listener.value }
        await disconnection?.value
        disconnection = nil
        try await db.disconnect()
    }

    /// "Réessayer" in Settings: uploads resume and the engine reconnects. The SDK keeps showing
    /// "connecting" after a disconnect, so the reconnection never depends on that state.
    func retry() async {
        do {
            if let saved = try await LocalMeta.recoveryBlock(in: db) {
                apply(saved)
                return
            }
            await disconnection?.value
            await connector.clearBlock()
            try await db.connect(connector: connector, crudThrottle: 1, retryDelay: 5)
        } catch {
            apply(.actionRequired(status: 0, code: "CONNECT_FAILED"))
        }
    }

    /// Back in the foreground: a block the server side may have fixed meanwhile is tried again.
    func resumeIfRecoverable() async {
        switch block {
        case .serverMisconfigured, .actionRequired(status: 0, _):
            await retry()
        default:
            break
        }
    }

    private func apply(_ newBlock: SyncBlock?) {
        block = newBlock
        guard let newBlock else { return }
        switch newBlock {
        case .generationChanged, .pairingRequired, .updateRequired, .serverMisconfigured:
            // Nothing is downloaded or sent until the user chooses; the queue and local data stay.
            let db = self.db
            disconnection?.cancel()
            disconnection = Task { try? await db.disconnect() }
        case .actionRequired:
            break
        }
    }

    /// A restored server shows a new generation in the replica even before an upload is refused.
    private func watchServerGeneration() {
        let db = self.db
        listeners.append(Task { [weak self] in
            do {
                let stream = try db.watch(sql: "SELECT id FROM server_meta", parameters: [], mapper: { cursor in
                    try cursor.getString(index: 0)
                })
                for try await generations in stream {
                    guard let current = generations.first,
                          let seen = try await LocalMeta.serverGeneration(in: db),
                          current.caseInsensitiveCompare(seen) != .orderedSame else { continue }
                    try Task.checkCancellation()
                    guard let self else { return }
                    try await self.connector.requireRecovery(.generationChanged(current))
                }
            } catch {
                // The watch ends with the engine; a new start installs it again.
            }
        })
    }
}
