import Foundation

/// Each step is idempotent. The journal is advanced only after the associated effect succeeds.
/// Session replacement and SQLite selection cannot be one OS transaction; this log bridges them.
@MainActor
protocol RecoveryInstallation: AnyObject {
    func verifyArchive(_ proof: RecoveryArchiveProof) async throws
    func prepareReplica(_ journal: RecoveryJournal) async throws
    func installCandidate(_ journal: RecoveryJournal) async throws
    func selectReplica(_ replica: RecoveryReplica) async throws
    func persistJournal(_ journal: RecoveryJournal) async throws
}

@MainActor
enum RecoveryInstaller {
    static func run(_ initial: RecoveryJournal, using installation: any RecoveryInstallation) async throws -> RecoveryJournal {
        var journal = initial
        try journal.validate()
        guard journal.switchWasConfirmed, let proof = journal.archive, let target = journal.target else {
            throw RecoveryError.confirmationRequired
        }
        try await installation.verifyArchive(proof)
        if journal.stage == .switchPrepared {
            try await installation.prepareReplica(journal)
            journal.stage = .replicaPrepared
            try await installation.persistJournal(journal)
        }
        if journal.stage == .replicaPrepared {
            try await installation.installCandidate(journal)
            journal.stage = .sessionInstalled
            try await installation.persistJournal(journal)
        }
        if journal.stage == .sessionInstalled {
            try await installation.selectReplica(target)
            journal.stage = .pointerInstalled
            try await installation.persistJournal(journal)
        }
        if journal.stage == .pointerInstalled {
            journal.stage = .complete
            try await installation.persistJournal(journal)
        }
        return journal
    }
}
