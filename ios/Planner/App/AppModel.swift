import Foundation
import Observation
import PowerSync
import UIKit

/// App lifecycle: paired or not, and the services of a paired iPhone.
@Observable
final class AppModel {
    enum Phase {
        case launching
        case unpaired
        case ready(AppServices)
        case failed(String)
    }

    private(set) var phase: Phase = .launching
    @ObservationIgnored private let credentials = CredentialStore()
    /// One database instance for the whole process (the sync engine requires it).
    @ObservationIgnored private var database: (any PowerSyncDatabaseProtocol)?

    func launch() async {
        guard case .launching = phase else { return }
        do {
            guard let session = try credentials.load() else {
                phase = .unpaired
                return
            }
            let services = makeServices(session)
            phase = .ready(services)
            await services.start()
        } catch {
            phase = .failed("L’appairage enregistré sur cet iPhone est illisible.")
        }
    }

    func pair(with link: PairingLink) async throws {
        let device = DeviceDescription(
            name: UIDevice.current.name,
            osVersion: UIDevice.current.systemVersion,
            appVersion: BuildInfo.current.version
        )
        let tokens = try await APIClient.pair(
            baseURL: link.apiURL, secret: link.secret, device: device, clientVersion: BuildInfo.current.clientVersionHeader
        )
        let session = StoredSession(apiBaseURL: link.apiURL, deviceId: tokens.deviceId, refreshToken: tokens.refreshToken)
        try credentials.save(session)
        let services = makeServices(session)
        try await LocalMeta.setServerGeneration(tokens.serverGeneration, in: services.db)
        await services.api.adopt(tokens)
        phase = .ready(services)
        await services.start()
    }

    /// Removes the pairing and this iPhone's copy of the data. Refused while commands wait to be sent.
    func unpair() async throws {
        guard case .ready(let services) = phase else { return }
        let pending = try await services.queue.pending()
        guard pending.count == 0 else { throw UnpairError.pendingCommands(pending.count) }
        try? await services.api.logout()
        await services.stop()
        try await services.db.disconnectAndClear()
        try credentials.delete()
        phase = .unpaired
    }

    private func makeServices(_ session: StoredSession) -> AppServices {
        let db = database ?? LocalDatabase.open()
        database = db
        let api = APIClient(session: session, clientVersion: BuildInfo.current.clientVersionHeader, credentials: credentials)
        return AppServices(db: db, api: api, session: session)
    }
}

nonisolated enum UnpairError: Error, Equatable {
    case pendingCommands(Int)
}

/// What a paired iPhone works with; injected into the views.
@Observable
final class AppServices {
    let db: any PowerSyncDatabaseProtocol
    let api: APIClient
    let session: StoredSession
    let tasks: TaskRepository
    let queue: SyncQueueRepository
    let sync: SyncController
    let directory: ProjectDirectory
    let undo = UndoCenter()

    init(db: any PowerSyncDatabaseProtocol, api: APIClient, session: StoredSession) {
        self.db = db
        self.api = api
        self.session = session
        tasks = TaskRepository(db: db)
        queue = SyncQueueRepository(db: db)
        sync = SyncController(db: db, api: api)
        directory = ProjectDirectory()
    }

    func start() async {
        directory.start(tasks)
        await sync.start()
    }

    func stop() async {
        directory.stop()
        await sync.stop()
    }
}

/// Lists and the Inbox count, observed once for all screens.
@Observable
final class ProjectDirectory {
    private(set) var projects: [ProjectItem] = []
    private(set) var inboxCount = 0
    @ObservationIgnored private var listeners: [Task<Void, Never>] = []

    func name(of projectId: String?) -> String? {
        guard let projectId else { return nil }
        return projects.first { $0.id == projectId }?.name
    }

    func start(_ repository: TaskRepository) {
        stop()
        listeners.append(Task { [weak self] in
            do {
                for try await projects in try repository.observeProjects() {
                    self?.projects = projects
                }
            } catch {}
        })
        listeners.append(Task { [weak self] in
            do {
                for try await counts in try repository.observeInboxCount() {
                    self?.inboxCount = counts.first ?? 0
                }
            } catch {}
        })
    }

    func stop() {
        for listener in listeners { listener.cancel() }
        listeners.removeAll()
    }
}

/// The short "Annuler" offered after a manual action; Terminées and Corbeille stay the durable way back.
@Observable
final class UndoCenter {
    struct Offer: Identifiable {
        let id = UUID()
        let message: String
        let action: @MainActor () async -> Void
    }

    private(set) var current: Offer?
    @ObservationIgnored private var expiry: Task<Void, Never>?

    func offer(_ message: String, undo: @escaping @MainActor () async -> Void) {
        let offer = Offer(message: message, action: undo)
        current = offer
        expiry?.cancel()
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, self?.current?.id == offer.id else { return }
            self?.current = nil
        }
    }

    func undo() async {
        guard let offer = current else { return }
        current = nil
        await offer.action()
    }

    func dismiss() {
        current = nil
    }
}
