import PowerSync

nonisolated enum RecoveryReplicaPreparation {
    /// Only the newly selected filename may receive new metadata. Reuse only verifies existing rows.
    static func prepare(_ journal: RecoveryJournal, db: any PowerSyncDatabaseProtocol) async throws {
        try journal.validate()
        guard journal.switchWasConfirmed, let candidate = journal.candidateIdentity,
              let userId = candidate.userId, let generation = candidate.generation else { throw RecoveryError.invalidJournal }
        if journal.choice == .newReplica {
            try await LocalMeta.setOwnerUserId(userId, in: db)
            try await LocalMeta.setServerGeneration(generation, in: db)
        } else {
            let owner = try await LocalMeta.ownerUserId(in: db)
            let seen = try await LocalMeta.serverGeneration(in: db)
            let identity = RecoveryIdentity(serverURL: journal.sourceIdentity.serverURL, userId: owner, generation: seen)
            guard try identity.decision(for: candidate) == .reuseReplica else { throw RecoveryError.invalidJournal }
        }
        try await LocalMeta.clearRecoveryBlock(in: db)
    }
}
