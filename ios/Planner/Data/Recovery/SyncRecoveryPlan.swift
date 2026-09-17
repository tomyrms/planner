import Foundation

/// The scope is persisted together: a new replica never opens the old assistant or audio drafts.
nonisolated struct RecoveryReplica: Codable, Equatable, Sendable {
    let databaseFilename: String
    let defaultsSuite: String?
    let audioScope: String?

    static let legacy = RecoveryReplica(databaseFilename: "planner.sqlite", defaultsSuite: nil, audioScope: nil)

    static func fresh(id: UUID = UUID()) -> Self {
        let name = id.uuidString.lowercased()
        return Self(databaseFilename: "planner-\(name).sqlite", defaultsSuite: "planner.replica.\(name)", audioScope: name)
    }

    var isValid: Bool {
        if self == .legacy { return true }
        guard let audioScope, UUID(uuidString: audioScope) != nil else { return false }
        return databaseFilename == "planner-\(audioScope).sqlite" && defaultsSuite == "planner.replica.\(audioScope)"
    }
}

nonisolated struct RecoveryIdentity: Codable, Equatable, Sendable {
    let serverURL: URL
    let userId: String?
    let generation: String?

    /// Keep the API path; normalize only URL spelling that cannot change the server identity.
    static func sameServer(_ first: URL, _ second: URL) -> Bool {
        func canonical(_ url: URL) -> String? {
            guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  parts.scheme?.lowercased() == "https", let host = parts.host,
                  parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else { return nil }
            parts.scheme = "https"
            parts.host = host.lowercased()
            if parts.port == 443 { parts.port = nil }
            while parts.path.hasSuffix("/") { parts.path.removeLast() }
            return parts.string
        }
        guard let left = canonical(first), let right = canonical(second) else { return false }
        return left == right
    }

    func decision(for candidate: Self) throws -> RecoveryDecision {
        guard Self.sameServer(serverURL, candidate.serverURL) else { throw RecoveryError.differentServer }
        guard let candidateUser = candidate.userId, !candidateUser.isEmpty,
              let candidateGeneration = candidate.generation, !candidateGeneration.isEmpty else {
            throw RecoveryError.missingIdentity
        }
        if let userId, userId.caseInsensitiveCompare(candidateUser) != .orderedSame { throw RecoveryError.differentUser }
        guard userId != nil, let generation else { return .newReplicaRequired(.identityUnproven) }
        return generation.caseInsensitiveCompare(candidateGeneration) == .orderedSame
            ? .reuseReplica : .newReplicaRequired(.generationChanged)
    }
}

nonisolated enum RecoveryDecision: Equatable, Sendable {
    enum Reason: String, Codable, Sendable { case identityUnproven, generationChanged }
    case reuseReplica
    case newReplicaRequired(Reason)
}

nonisolated enum RecoveryError: Error, Equatable, Sendable {
    case differentServer, differentUser, missingIdentity, archiveNotVerified, invalidJournal
    case candidateMissing, confirmationRequired, recordingStillFinishing

    var message: String {
        switch self {
        case .differentServer: "Ce lien appartient à un autre serveur. Utilisez un lien du serveur déjà associé à cet iPhone."
        case .differentUser: "Ce lien appartient à un autre utilisateur. La copie locale et ses commandes restent conservées, sans être envoyées."
        case .missingIdentity: "Le serveur ne permet pas de vérifier l’identité et la génération. Mettez-le à jour avant de continuer."
        case .archiveNotVerified: "L’archive locale n’a pas pu être vérifiée. Aucun remplacement de réplique n’est autorisé. Réessayez l’archivage."
        case .invalidJournal: "L’état de récupération enregistré est illisible. Les fichiers locaux sont conservés ; aucune synchronisation n’est démarrée."
        case .candidateMissing: "L’appairage préparé n’est plus disponible dans le trousseau. Collez un nouveau lien d’appairage."
        case .confirmationRequired: "Choisissez explicitement la reprise proposée avant de continuer."
        case .recordingStillFinishing: "Le vocal est encore en cours de finalisation. Attendez, puis réessayez la préparation de l’archive."
        }
    }
}

nonisolated struct RecoveryArchiveProof: Codable, Equatable, Sendable {
    let filename: String
    let byteCount: Int
    let sha256: String
}

/// No token, pairing link, transcript or audio path belongs in this journal.
nonisolated struct RecoveryJournal: Codable, Equatable, Sendable {
    enum Stage: String, Codable, Sendable {
        case archiving, archiveReady, candidateReady, switchPrepared, replicaPrepared, sessionInstalled, pointerInstalled, complete
    }
    enum Choice: String, Codable, Sendable { case reuseReplica, newReplica }
    let id: UUID
    let createdAt: Date
    let source: RecoveryReplica
    let sourceIdentity: RecoveryIdentity
    var archive: RecoveryArchiveProof?
    var candidateIdentity: RecoveryIdentity?
    var candidateDeviceId: String?
    var target: RecoveryReplica?
    var choice: Choice?
    var stage: Stage

    init(source: RecoveryReplica, identity: RecoveryIdentity, id: UUID = UUID(), at: Date = Date()) {
        self.id = id
        createdAt = at
        self.source = source
        sourceIdentity = identity
        stage = .archiving
    }

    var switchWasConfirmed: Bool {
        switch stage {
        case .switchPrepared, .replicaPrepared, .sessionInstalled, .pointerInstalled, .complete: true
        default: false
        }
    }

    func validate() throws {
        guard source.isValid, RecoveryIdentity.sameServer(sourceIdentity.serverURL, sourceIdentity.serverURL) else {
            throw RecoveryError.invalidJournal
        }
        if stage != .archiving, archive == nil { throw RecoveryError.invalidJournal }
        if stage != .archiving && stage != .archiveReady {
            guard let candidateIdentity, candidateDeviceId != nil else { throw RecoveryError.invalidJournal }
            let decision = try sourceIdentity.decision(for: candidateIdentity)
            if switchWasConfirmed {
                guard let target, target.isValid, let choice else { throw RecoveryError.invalidJournal }
                switch (decision, choice) {
                case (.reuseReplica, .reuseReplica):
                    guard target == source else { throw RecoveryError.invalidJournal }
                case (.newReplicaRequired, .newReplica):
                    guard target != source else { throw RecoveryError.invalidJournal }
                default: throw RecoveryError.invalidJournal
                }
            }
        }
    }
}
