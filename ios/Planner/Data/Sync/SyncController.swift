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

    init(db: any PowerSyncDatabaseProtocol, api: APIClient) {
        self.db = db
        let (stream, continuation) = AsyncStream.makeStream(of: SyncBlock?.self)
        connector = SyncConnector(api: api, events: continuation)
        listeners.append(Task { [weak self] in
            for await block in stream {
                self?.apply(block)
            }
        })
    }

    /// Live engine state (connected, uploading, last sync…), observable by the views.
    var status: ObservableSyncStatus {
        db.currentStatus.observable
    }

    func start() async {
        watchServerGeneration()
        do {
            try await db.connect(connector: connector, crudThrottle: 1, retryDelay: 5)
        } catch {
            apply(.actionRequired(status: 0, code: "CONNECT_FAILED"))
        }
    }

    func stop() async {
        for listener in listeners { listener.cancel() }
        listeners.removeAll()
        try? await db.disconnect()
    }

    /// "Réessayer" in Settings: uploads resume; a stopped engine reconnects.
    func retry() async {
        await connector.clearBlock()
        if !status.connected && !status.connecting {
            try? await db.connect(connector: connector, crudThrottle: 1, retryDelay: 5)
        }
    }

    private func apply(_ newBlock: SyncBlock?) {
        block = newBlock
        guard let newBlock else { return }
        switch newBlock {
        case .generationChanged, .pairingRequired, .updateRequired, .serverMisconfigured:
            // Nothing is downloaded or sent until the user chooses; the queue and local data stay.
            let db = self.db
            Task { try? await db.disconnect() }
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
                    self?.apply(.generationChanged(current))
                }
            } catch {
                // The watch ends with the engine; a new start installs it again.
            }
        })
    }
}
