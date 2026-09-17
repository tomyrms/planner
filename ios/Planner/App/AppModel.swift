import Foundation
import Observation
import PowerSync
import UIKit

/// App lifecycle: paired or not, and the services of a paired iPhone.
@Observable
final class AppModel: RecoveryInstallation {
    enum Phase {
        case launching
        case unpaired
        case ready(AppServices)
        case recovering(AppServices)
        case failed(String)
    }

    private(set) var phase: Phase = .launching
    let recovery = SyncRecoveryState()
    @ObservationIgnored private let credentials = CredentialStore()
    @ObservationIgnored private let candidateCredentials = CredentialStore(account: "recovery-candidate")
    @ObservationIgnored private let recoveryFiles = RecoveryFiles()
    /// One instance per filename; an archived replica is never cleared to initialize its replacement.
    @ObservationIgnored private var databases: [String: any PowerSyncDatabaseProtocol] = [:]
    @ObservationIgnored private var activeReplica = RecoveryReplica.legacy
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private var audioRetentionTask: Task<Void, Never>?

    func launch() async {
        guard case .launching = phase else { return }
        do {
            let journal = try await recoveryFiles.journal()
            activeReplica = try await recoveryFiles.activeReplica()
            startRetiredAudioRetention()
            guard let session = try credentials.load() ?? (journal != nil ? candidateCredentials.load() : nil) else {
                if journal != nil { throw RecoveryError.candidateMissing }
                phase = .unpaired
                return
            }
            if let journal {
                recovery.journal = journal
                let services = try await makeServices(session, replica: journal.source, suspended: true)
                phase = .recovering(services)
                if journal.switchWasConfirmed { resumeRecovery() }
                return
            }
            let services = try await makeServices(session, replica: activeReplica)
            phase = .ready(services)
            await services.start()
        } catch let error as RecoveryError {
            phase = .failed(error.message)
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
        let session = StoredSession(apiBaseURL: link.apiURL, deviceId: tokens.deviceId, refreshToken: tokens.refreshToken, userId: tokens.userId)
        // A missing Keychain item must never cause an old, possibly foreign replica to be reused.
        let replica = RecoveryReplica.fresh()
        let services = try await makeServices(session, replica: replica)
        try await LocalMeta.setServerGeneration(tokens.serverGeneration, in: services.db)
        try await LocalMeta.setOwnerUserId(tokens.userId, in: services.db)
        try await recoveryFiles.select(replica)
        try credentials.save(session)
        activeReplica = replica
        startRetiredAudioRetention()
        await services.api.adopt(tokens)
        phase = .ready(services)
        await services.start()
    }

    /// Removes the pairing and this iPhone's copy of the data. Refused while commands wait to be sent.
    func unpair() async throws {
        guard case .ready(let services) = phase else { return }
        let pending = try await services.queue.pending()
        guard pending.count == 0 else { throw UnpairError.pendingCommands(pending.count) }
        services.voice.stop()
        services.assistant.stopRequests()
        try? await services.api.logout()
        await services.api.retire()
        await services.stop()
        try await services.db.disconnectAndClear()
        try credentials.delete()
        services.assistant.clearPairingState()
        phase = .unpaired
    }

    private func makeServices(_ session: StoredSession, replica: RecoveryReplica, suspended: Bool = false) async throws -> AppServices {
        let db = database(for: replica)
        let api = APIClient(session: session, clientVersion: BuildInfo.current.clientVersionHeader,
                            credentials: credentials, requireIdentityValidation: true)
        let audioDirectory = try await recoveryFiles.audioDirectory(for: replica)
        let defaults: UserDefaults
        if let suite = replica.defaultsSuite {
            guard let scoped = UserDefaults(suiteName: suite) else { throw RecoveryError.invalidJournal }
            defaults = scoped
        } else { defaults = .standard }
        return AppServices(db: db, api: api, session: session, defaults: defaults, audioDirectory: audioDirectory, suspended: suspended)
    }

    private func database(for replica: RecoveryReplica) -> any PowerSyncDatabaseProtocol {
        if let existing = databases[replica.databaseFilename] { return existing }
        let db = LocalDatabase.open(fileName: replica.databaseFilename)
        databases[replica.databaseFilename] = db
        return db
    }

    // MARK: - Guided recovery. This model owns the task even while its view is replaced.

    func prepareRecovery() {
        runRecovery { [self] in
            let services: AppServices
            switch phase {
            case .ready(let current), .recovering(let current): services = current
            default: throw RecoveryError.invalidJournal
            }
            // Freeze the UI before the first suspension point. Capture sync observations before disconnect.
            let context = LocalExportContext(hasSynced: services.sync.hasSynced, lastSyncedAt: services.sync.lastSyncedAt,
                                             connection: "recovery_suspended", generationChanged: {
                if case .generationChanged = services.sync.block { return true }; return false
            }())
            phase = .recovering(services)
            services.isRecoverySuspended = true
            if recovery.journal == nil {
                let identity = RecoveryIdentity(
                    serverURL: services.session.apiBaseURL,
                    userId: try await LocalMeta.ownerUserId(in: services.db),
                    generation: try await LocalMeta.serverGeneration(in: services.db)
                )
                let journal = RecoveryJournal(source: activeReplica, identity: identity)
                try await recoveryFiles.save(journal)
                recovery.journal = journal
            }
            try await services.suspendForRecovery()
            guard var journal = recovery.journal else { throw RecoveryError.invalidJournal }
            // Recreating a failed archive is safe only before a candidate/switch has been prepared.
            guard journal.stage == .archiving || journal.stage == .archiveReady else { return }
            let data = try await LocalExportRepository(db: services.db).data(context: context, drafts: services.exportDrafts())
            journal.archive = try await recoveryFiles.archive(data, journalId: journal.id)
            journal.stage = .archiveReady
            try await persistJournal(journal)
            recovery.archiveData = data
            recovery.message = "Archive locale enregistrée et vérifiée. Collez un nouveau lien d’appairage du même serveur."
        }
    }

    func verifyRecoveryLink(_ link: PairingLink) {
        runRecovery { [self] in
            guard var journal = recovery.journal, journal.stage == .archiveReady || journal.stage == .candidateReady,
                  let proof = journal.archive else { throw RecoveryError.invalidJournal }
            guard RecoveryIdentity.sameServer(journal.sourceIdentity.serverURL, link.apiURL) else { throw RecoveryError.differentServer }
            try await recoveryFiles.verify(proof)
            let tokens = try await APIClient.pair(baseURL: link.apiURL, secret: link.secret, device: DeviceDescription(
                name: UIDevice.current.name, osVersion: UIDevice.current.systemVersion, appVersion: BuildInfo.current.version
            ), clientVersion: BuildInfo.current.clientVersionHeader)
            let identity = RecoveryIdentity(serverURL: link.apiURL, userId: tokens.userId, generation: tokens.serverGeneration)
            _ = try journal.sourceIdentity.decision(for: identity)
            let session = StoredSession(apiBaseURL: link.apiURL, deviceId: tokens.deviceId, refreshToken: tokens.refreshToken, userId: tokens.userId)
            try candidateCredentials.save(session)
            journal.candidateIdentity = identity
            journal.candidateDeviceId = tokens.deviceId
            journal.stage = .candidateReady
            try await persistJournal(journal)
            recovery.message = nil
        }
    }

    func confirmRecovery(newReplica: Bool) {
        runRecovery { [self] in
            guard var journal = recovery.journal, journal.stage == .candidateReady, let candidate = journal.candidateIdentity else {
                throw RecoveryError.confirmationRequired
            }
            let decision = try journal.sourceIdentity.decision(for: candidate)
            switch (decision, newReplica) {
            case (.reuseReplica, false): journal.choice = .reuseReplica; journal.target = journal.source
            case (.newReplicaRequired, true): journal.choice = .newReplica; journal.target = .fresh()
            default: throw RecoveryError.confirmationRequired
            }
            // The explicit choice and target filename are durable before replacing the session.
            journal.stage = .switchPrepared
            try await persistJournal(journal)
            try await completeRecovery()
        }
    }

    func resumeRecovery() {
        runRecovery { [self] in try await completeRecovery() }
    }

    func resetRecoveryCandidate() {
        runRecovery { [self] in
            guard var journal = recovery.journal,
                  [.candidateReady, .switchPrepared, .replicaPrepared].contains(journal.stage) else { throw RecoveryError.invalidJournal }
            journal.candidateIdentity = nil
            journal.candidateDeviceId = nil
            journal.target = nil
            journal.choice = nil
            journal.stage = .archiveReady
            try await persistJournal(journal)
            try? candidateCredentials.delete()
        }
    }

    func loadRecoveryArchive() {
        runRecovery { [self] in
            guard let proof = recovery.journal?.archive else { throw RecoveryError.archiveNotVerified }
            recovery.archiveData = try await recoveryFiles.archiveData(proof)
        }
    }

    func recoveryArchives() async throws -> [RecoveryJournal] { try await recoveryFiles.completedJournals() }
    func recoveryArchiveData(_ proof: RecoveryArchiveProof) async throws -> Data { try await recoveryFiles.archiveData(proof) }

    private func runRecovery(_ action: @escaping @MainActor () async throws -> Void) {
        guard recoveryTask == nil else { return }
        recovery.isBusy = true
        recovery.message = nil
        recoveryTask = Task { [weak self] in
            defer { self?.recovery.isBusy = false; self?.recoveryTask = nil }
            do { try await action() }
            catch let error as RecoveryError { self?.recovery.message = error.message }
            catch let error as APIError { self?.recovery.message = Self.recoveryMessage(error) }
            catch { self?.recovery.message = "La récupération n’a pas abouti. Les données et la file locales restent conservées. Réessayez." }
        }
    }

    private func completeRecovery() async throws {
        guard let saved = try await recoveryFiles.journal(), saved.switchWasConfirmed else { throw RecoveryError.confirmationRequired }
        if case .recovering(let services) = phase { try await services.suspendForRecovery() }
        let complete = try await RecoveryInstaller.run(saved, using: self)
        guard let target = complete.target, let candidate = complete.candidateIdentity,
              let session = try credentials.load(), Self.matches(session, identity: candidate, deviceId: complete.candidateDeviceId) else {
            throw RecoveryError.candidateMissing
        }
        let services = try await makeServices(session, replica: target)
        // The completion barrier stays in place until constructing all replacement services succeeds.
        try await recoveryFiles.finish(complete)
        try? candidateCredentials.delete()
        activeReplica = target
        startRetiredAudioRetention()
        recovery.journal = nil
        recovery.archiveData = nil
        recovery.message = nil
        phase = .ready(services)
        await services.start()
    }

    func verifyArchive(_ proof: RecoveryArchiveProof) async throws { try await recoveryFiles.verify(proof) }

    func prepareReplica(_ journal: RecoveryJournal) async throws {
        guard let target = journal.target else { throw RecoveryError.invalidJournal }
        try await RecoveryReplicaPreparation.prepare(journal, db: database(for: target))
    }

    func installCandidate(_ journal: RecoveryJournal) async throws {
        guard let identity = journal.candidateIdentity, let session = try candidateCredentials.load(),
              Self.matches(session, identity: identity, deviceId: journal.candidateDeviceId) else { throw RecoveryError.candidateMissing }
        // A refresh belonging to the former device must not write after this save.
        if case .recovering(let services) = phase { await services.api.retire() }
        try credentials.save(session)
    }

    func selectReplica(_ replica: RecoveryReplica) async throws { try await recoveryFiles.select(replica) }

    func persistJournal(_ journal: RecoveryJournal) async throws {
        try await recoveryFiles.save(journal)
        recovery.journal = journal
    }

    private static func matches(_ session: StoredSession, identity: RecoveryIdentity, deviceId: String?) -> Bool {
        RecoveryIdentity.sameServer(session.apiBaseURL, identity.serverURL) && session.userId == identity.userId && session.deviceId == deviceId
    }

    private static func recoveryMessage(_ error: APIError) -> String {
        switch error {
        case .unauthorized: "Lien refusé ou expiré. Générez un nouveau lien sur le même serveur."
        case .transport: "Le serveur est injoignable. L’archive est conservée ; vérifiez la connexion puis réessayez."
        case .http(let status, let code, _, _, _, _): "Appairage refusé (\(code ?? "HTTP \(status)")). L’ancienne copie reste conservée."
        case .invalidResponse: "Réponse du serveur invalide. Aucun remplacement de la copie locale n’a été effectué."
        }
    }

    private func startRetiredAudioRetention() {
        audioRetentionTask?.cancel()
        let files = recoveryFiles
        let replica = activeReplica
        audioRetentionTask = Task {
            do {
                while !Task.isCancelled {
                    guard let next = try await files.pruneRetiredAudio(excluding: replica) else { return }
                    try await Task.sleep(for: .seconds(max(1, next)))
                }
            } catch { /* Retry the local retention sweep on the next launch or replica change. */ }
        }
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
    let assistantHistory: AssistantRepository
    let assistant: AssistantStore
    let voice: VoiceMessageStore
    let agenda = AgendaStore()
    let reminders: ReminderReconciler
    let navigator = Navigator()
    var isRecoverySuspended: Bool
    @ObservationIgnored private var recoveryQuiesced: Bool
    @ObservationIgnored private var serviceLifecycleId: UUID?

    init(db: any PowerSyncDatabaseProtocol, api: APIClient, session: StoredSession,
         defaults: UserDefaults = .standard, audioDirectory: URL? = nil, suspended: Bool = false) {
        self.db = db
        self.api = api
        self.session = session
        isRecoverySuspended = suspended
        // These services were constructed for an incomplete journal and have never been started.
        recoveryQuiesced = suspended
        tasks = TaskRepository(db: db)
        queue = SyncQueueRepository(db: db)
        sync = SyncController(db: db, api: api)
        directory = ProjectDirectory()
        assistantHistory = AssistantRepository(db: db)
        assistant = AssistantStore(api: api, repository: assistantHistory, defaults: defaults)
        // Initialization may expire an old audio file; it must not issue requests before start().
        voice = VoiceMessageStore(api: api, assistant: assistant, defaults: defaults, audioDirectory: audioDirectory, suspended: true)
        if suspended { assistant.stopRequests() }
        reminders = ReminderReconciler(db: db)
    }

    func start() async {
        guard !isRecoverySuspended else { return }
        let lifecycle = UUID()
        serviceLifecycleId = lifecycle
        directory.start(tasks)
        agenda.start(tasks)
        await reminders.start()
        guard serviceLifecycleId == lifecycle, !isRecoverySuspended, !Task.isCancelled else { return }
        let reminders = self.reminders
        assistant.onResult = { reminders.requestPass() }
        let navigator = self.navigator
        NotificationRouter.shared.attach(
            open: { target in navigator.target = target },
            complete: { [weak self] target in await self?.complete(target) }
        )
        await sync.start()
        await resumeOnlineActions()
    }

    func resumeOnlineActions() async {
        guard !isRecoverySuspended else { return }
        let verified = await sync.validateBeforeOnlineActions()
        guard !isRecoverySuspended else { return }
        // Local recording remains possible offline. APIClient separately guards every remote mutation.
        voice.activateRequests()
        if verified { await voice.appDidBecomeActive() }
    }

    func stop() async {
        serviceLifecycleId = nil
        NotificationRouter.shared.detach()
        voice.stop()
        assistant.stopRequests()
        assistant.stop()
        directory.stop()
        agenda.stop()
        await reminders.stopAndWait()
        await sync.stop()
    }

    /// Freeze all producers; keep the SQLite queue, composer, pending assistant IDs and audio draft.
    func suspendForRecovery() async throws {
        serviceLifecycleId = nil
        isRecoverySuspended = true
        if recoveryQuiesced {
            await api.retire()
            return
        }
        NotificationRouter.shared.detach()
        assistant.stopRequests()
        assistant.stop()
        directory.stop()
        agenda.stop()
        await reminders.stopAndWait()
        await api.retire()
        try await sync.suspendForRecovery()
        try await voice.suspendPreservingDraft()
        recoveryQuiesced = true
    }

    func exportDrafts() -> LocalExportDrafts {
        LocalExportDrafts(
            assistantConversationId: assistant.conversationId,
            assistantText: assistant.draft.isEmpty ? nil : assistant.draft,
            pendingAssistant: assistant.pending,
            voice: voice.draft.map {
                LocalExportVoiceText(transcriptionId: $0.transcriptionId, conversationId: $0.conversationId,
                                    state: $0.state.rawValue, transcript: $0.transcript, pendingAssistant: $0.handoff)
            }
        )
    }

    /// "Terminé" from a notification (§1.8): the object is read again; nothing happens if it is already
    /// done or deleted; otherwise the same command as the UI.
    func complete(_ target: OpenTarget) async {
        guard !isRecoverySuspended else { return }
        guard let task = try? await tasks.task(id: target.taskId), !task.isDeleted, !task.isCompleted else { return }
        if task.isRecurring {
            guard let key = target.occurrenceKey else { return }
            let status = try? await tasks.occurrenceStatus(taskId: task.id, key: key)
            guard status == nil || status == .open else { return }
            try? await tasks.closeOccurrence(task, key: key, skip: false)
        } else {
            try? await tasks.setCompleted(task.id, true)
        }
        reminders.requestPass()
    }
}

/// Where a notification asks to go: a task, or one occurrence of a series.
nonisolated struct OpenTarget: Identifiable, Hashable, Sendable {
    let taskId: String
    let occurrenceKey: String?

    var id: String { "\(taskId):\(occurrenceKey ?? "")" }
}

/// The screen a notification opens, presented above the tabs.
@Observable
final class Navigator {
    var target: OpenTarget?
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
