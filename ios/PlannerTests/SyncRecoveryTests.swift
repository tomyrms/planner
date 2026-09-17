import Foundation
import PowerSync
import Testing
@testable import Planner

@MainActor
struct SyncRecoveryTests {
    private let server = URL(string: "https://planner.example.test")!

    @Test func foreignServerAndKnownForeignOwnerAreRefused() throws {
        let source = RecoveryIdentity(serverURL: server, userId: "owner", generation: "generation-1")
        #expect(throws: RecoveryError.differentServer) {
            try source.decision(for: RecoveryIdentity(serverURL: URL(string: "https://other.example.test")!, userId: "owner", generation: "generation-1"))
        }
        #expect(throws: RecoveryError.differentUser) {
            try source.decision(for: RecoveryIdentity(serverURL: server, userId: "other", generation: "generation-1"))
        }
        #expect(!RecoveryIdentity.sameServer(server, URL(string: "https://planner.example.test/another-api")!))
        #expect(RecoveryIdentity.sameServer(server, URL(string: "https://PLANNER.example.test:443/")!))
    }

    @Test func legacyIdentityOrChangedGenerationRequireANewReplica() throws {
        let candidate = RecoveryIdentity(serverURL: server, userId: "owner", generation: "generation-2")
        let legacy = try RecoveryIdentity(serverURL: server, userId: nil, generation: "generation-2").decision(for: candidate)
        let restored = try RecoveryIdentity(serverURL: server, userId: "owner", generation: "generation-1").decision(for: candidate)
        let same = try RecoveryIdentity(serverURL: server, userId: "owner", generation: "generation-2").decision(for: candidate)
        #expect(legacy == .newReplicaRequired(.identityUnproven))
        #expect(restored == .newReplicaRequired(.generationChanged))
        #expect(same == .reuseReplica)
    }

    @Test func archiveIsReadBackVerifiedAndCorruptionBlocksEveryInstallationEffect() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var journal = journalForNewReplica()
        let proof = try await fixture.files.archive(fixture.archive, journalId: journal.id)
        journal.archive = proof
        try await fixture.files.save(journal)
        try Data("broken".utf8).write(to: fixture.directory.appending(path: proof.filename))
        let installer = FakeRecoveryInstallation(files: fixture.files)
        await #expect(throws: RecoveryError.archiveNotVerified) {
            try await RecoveryInstaller.run(journal, using: installer)
        }
        #expect(installer.effects.isEmpty)
        let after = try await fixture.files.journal()
        #expect(after == journal)
    }

    @Test func invalidExportDoesNotCreateAnArchiveReceipt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        await #expect(throws: RecoveryError.archiveNotVerified) {
            try await fixture.files.archive(Data("{}".utf8), journalId: UUID())
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path(percentEncoded: false))
        #expect(files.isEmpty)
    }

    @Test func preparedCandidateWithoutExplicitChoiceCannotReplaceSessionOrReplica() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var journal = journalForNewReplica()
        journal.archive = try await fixture.files.archive(fixture.archive, journalId: journal.id)
        journal.stage = .candidateReady
        journal.choice = nil
        journal.target = nil
        let installer = FakeRecoveryInstallation(files: fixture.files)
        await #expect(throws: RecoveryError.confirmationRequired) {
            try await RecoveryInstaller.run(journal, using: installer)
        }
        #expect(installer.effects.isEmpty)
    }

    @Test(arguments: [RecoveryJournal.Stage.replicaPrepared, .sessionInstalled, .pointerInstalled, .complete])
    func crashAfterEachEffectResumesFromTheLastDurableJournal(failedStage: RecoveryJournal.Stage) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var journal = journalForNewReplica()
        journal.archive = try await fixture.files.archive(fixture.archive, journalId: journal.id)
        try await fixture.files.save(journal)
        let installer = FakeRecoveryInstallation(files: fixture.files, failBeforeSaving: failedStage)
        await #expect(throws: SimulatedCrash.self) { try await RecoveryInstaller.run(journal, using: installer) }
        let savedValue = try await fixture.files.journal()
        let saved = try #require(savedValue)
        #expect(saved.stage != failedStage)
        #expect(saved.switchWasConfirmed)
        installer.failBeforeSaving = nil
        let complete = try await RecoveryInstaller.run(saved, using: installer)
        #expect(complete.stage == .complete)
        let selected = try await fixture.files.activeReplica()
        #expect(selected == journal.target)
        #expect(installer.installedDevice == journal.candidateDeviceId)
        #expect(installer.effects.first == "prepare")
        try await fixture.files.finish(complete)
        let remaining = try await fixture.files.journal()
        #expect(remaining == nil)
        let archiveProof = try #require(journal.archive)
        let retainedArchive = try await fixture.files.archiveData(archiveProof)
        #expect(retainedArchive == fixture.archive)
        let accessible = try await fixture.files.completedJournals()
        #expect(accessible.map(\.id) == [complete.id])
    }

    @Test func sameReplicaRecoveryKeepsEveryQueuedByteAndCommandIdentifier() async throws {
        try await withDatabase { db in
            try await LocalMeta.setOwnerUserId("owner", in: db)
            try await LocalMeta.setServerGeneration("generation-1", in: db)
            try await LocalMeta.setRecoveryBlock(.pairingRequired, in: db)
            var draft = TaskDraft()
            draft.title = "Intention hors ligne"
            let repository = TaskRepository(db: db)
            let id = try await repository.create(draft)
            var changed = draft
            changed.notes = "À préserver"
            try await repository.update(id, from: draft, to: changed)
            let before = try await queue(db)
            var journal = journalForNewReplica()
            journal.candidateIdentity = journal.sourceIdentity
            journal.choice = .reuseReplica
            journal.target = journal.source
            try await RecoveryReplicaPreparation.prepare(journal, db: db)
            let after = try await queue(db)
            let owner = try await LocalMeta.ownerUserId(in: db)
            let generation = try await LocalMeta.serverGeneration(in: db)
            let block = try await LocalMeta.recoveryBlock(in: db)
            #expect(!before.isEmpty)
            #expect(before == after)
            #expect(owner == "owner")
            #expect(generation == "generation-1")
            #expect(block == nil)
        }
    }

    @Test func newReplicaStartsEmptyWhileOriginalQueueAndGenerationRemain() async throws {
        try await withDatabase { source in
            try await LocalMeta.setOwnerUserId("owner", in: source)
            try await LocalMeta.setServerGeneration("generation-1", in: source)
            var draft = TaskDraft()
            draft.title = "Ancienne génération"
            _ = try await TaskRepository(db: source).create(draft)
            let before = try await queue(source)
            try await withDatabase { target in
                try await RecoveryReplicaPreparation.prepare(journalForNewReplica(), db: target)
                let oldQueue = try await queue(source)
                let newQueue = try await queue(target)
                let oldGeneration = try await LocalMeta.serverGeneration(in: source)
                let newGeneration = try await LocalMeta.serverGeneration(in: target)
                #expect(oldQueue == before)
                #expect(newQueue.isEmpty)
                #expect(oldGeneration == "generation-1")
                #expect(newGeneration == "generation-2")
            }
        }
    }

    @Test(arguments: [true, false])
    func resuspendingAnAlreadyFrozenServiceDoesNotReinstallAClearedRecoveryBlock(initiallySuspended: Bool) async throws {
        let fixture = try Fixture()
        let suiteName = "recovery-drafts-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName); fixture.remove() }
        try await withDatabase { db in
            let session = StoredSession(apiBaseURL: server, deviceId: "test-device", refreshToken: "unused-test-token", userId: "owner")
            let api = APIClient(session: session, clientVersion: "1.0.0", credentials: CredentialStore(account: "unused-\(UUID().uuidString)"))
            let services = AppServices(db: db, api: api, session: session, defaults: defaults,
                                       audioDirectory: fixture.directory, suspended: initiallySuspended)
            if !initiallySuspended {
                try await services.suspendForRecovery()
                try await LocalMeta.clearRecoveryBlock(in: db)
            }
            try await services.suspendForRecovery()
            let block = try await LocalMeta.recoveryBlock(in: db)
            #expect(block == nil)
            #expect(services.isRecoverySuspended)
            await services.stop()
        }
    }

    @Test func journalAndPointerRoundTripScopesWithoutSecretsOrArchiveContent() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var journal = journalForNewReplica()
        journal.archive = try await fixture.files.archive(fixture.archive, journalId: journal.id)
        try await fixture.files.save(journal)
        let restored = try await fixture.files.journal()
        #expect(restored == journal)
        let text = String(decoding: try Data(contentsOf: fixture.directory.appending(path: "current.json")), as: UTF8.self)
        for forbidden in ["refreshToken", "accessToken", "pairingSecret", "transcript", "pendingCommands", "secret-text"] {
            #expect(!text.contains(forbidden))
        }
        let target = try #require(journal.target)
        #expect(target.databaseFilename != journal.source.databaseFilename)
        #expect(target.defaultsSuite != journal.source.defaultsSuite)
        #expect(target.audioScope != journal.source.audioScope)
    }

    private func journalForNewReplica() -> RecoveryJournal {
        var value = RecoveryJournal(source: .legacy, identity: RecoveryIdentity(serverURL: server, userId: "owner", generation: "generation-1"))
        value.archive = RecoveryArchiveProof(filename: "archive-test.json", byteCount: 1, sha256: "placeholder")
        value.candidateIdentity = RecoveryIdentity(serverURL: server, userId: "owner", generation: "generation-2")
        value.candidateDeviceId = "new-device"
        value.target = .fresh()
        value.choice = .newReplica
        value.stage = .switchPrepared
        return value
    }

    private func queue(_ db: any PowerSyncDatabaseProtocol) async throws -> [String] {
        try await db.getAll(sql: "SELECT data FROM ps_crud ORDER BY id", parameters: []) { try $0.getString(index: 0) }
    }

    private func withDatabase(_ body: @MainActor (any PowerSyncDatabaseProtocol) async throws -> Void) async throws {
        let db = LocalDatabase.open(fileName: "recovery-test-\(UUID().uuidString).sqlite")
        do {
            try await body(db)
            try await db.disconnectAndClear()
        } catch {
            try? await db.disconnectAndClear()
            throw error
        }
    }

    private struct Fixture {
        let directory: URL
        let files: RecoveryFiles
        let archive = Data(#"{"localExportVersion":1,"pendingCommands":[],"drafts":{"assistantText":"secret-text"}}"#.utf8)

        init() throws {
            directory = URL.temporaryDirectory.appending(path: "Recovery tests \(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            files = RecoveryFiles(directory: directory)
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}

private struct SimulatedCrash: Error {}

@MainActor
private final class FakeRecoveryInstallation: RecoveryInstallation {
    let files: RecoveryFiles
    var failBeforeSaving: RecoveryJournal.Stage?
    var effects: [String] = []
    var installedDevice: String?

    init(files: RecoveryFiles, failBeforeSaving: RecoveryJournal.Stage? = nil) {
        self.files = files
        self.failBeforeSaving = failBeforeSaving
    }

    func verifyArchive(_ proof: RecoveryArchiveProof) async throws { try await files.verify(proof) }
    func prepareReplica(_ journal: RecoveryJournal) async throws { effects.append("prepare") }
    func installCandidate(_ journal: RecoveryJournal) async throws {
        effects.append("session")
        installedDevice = journal.candidateDeviceId
    }
    func selectReplica(_ replica: RecoveryReplica) async throws {
        effects.append("pointer")
        try await files.select(replica)
    }
    func persistJournal(_ journal: RecoveryJournal) async throws {
        if journal.stage == failBeforeSaving { throw SimulatedCrash() }
        try await files.save(journal)
    }
}
