import Foundation

/// Authenticated, content-free snapshot from GET /diagnostics (API contract §6).
nonisolated struct DiagnosticsSnapshot: Decodable, Sendable, Equatable {
    enum Sync: String, Decodable, Sendable { case provisioned, notProvisioned = "not_provisioned" }
    enum ProviderStatus: String, Decodable, Sendable { case configured, disabled }

    struct Assistant: Decodable, Sendable, Equatable {
        let status: ProviderStatus
        let provider: String?
        let model: String?
        let monthTokens: Int64
        let monthTokenBudget: Int64
    }

    struct Transcription: Decodable, Sendable, Equatable {
        let status: ProviderStatus
        let provider: String?
        let model: String?
        let monthMinutes: Double
        let monthMinuteBudget: Int64
    }

    struct Maintenance: Decodable, Sendable, Equatable {
        let backup: DiagnosticsRun
        let backupVerify: DiagnosticsRun
        let restore: DiagnosticsRun
        let purge: DiagnosticsRun
        let audioCleanup: DiagnosticsRun
    }

    let generatedAt: String
    let serverGeneration: String
    let minimumClientVersion: String
    let sync: Sync
    let replicationLagBytes: Int64?
    let assistant: Assistant
    let transcription: Transcription
    let maintenance: Maintenance
}

nonisolated struct DiagnosticsRun: Decodable, Sendable, Equatable {
    enum State: Equatable, Sendable { case unknown, inconsistent, failed, stale, succeeded }

    let lastSucceededAt: String?
    let lastFailedAt: String?

    var succeededAt: Date? { Timestamp.parse(lastSucceededAt) }
    var failedAt: Date? { Timestamp.parse(lastFailedAt) }

    /// A past success must not hide a later failure, missing evidence, or an overdue daily job.
    func state(at now: Date, maximumAge: TimeInterval?) -> State {
        let success = succeededAt
        let failure = failedAt
        if (lastSucceededAt != nil && success == nil) || (lastFailedAt != nil && failure == nil) {
            return .inconsistent
        }
        if [success, failure].compactMap({ $0 }).contains(where: { $0 > now.addingTimeInterval(300) }) {
            return .inconsistent
        }
        if let failure {
            guard let success else { return .failed }
            if failure >= success { return .failed }
        }
        guard let success else { return .unknown }
        if let maximumAge, now.timeIntervalSince(success) > maximumAge { return .stale }
        return .succeeded
    }
}

nonisolated protocol DiagnosticsAPI: Sendable {
    func diagnostics() async throws -> DiagnosticsSnapshot
}

extension APIClient: DiagnosticsAPI {
    func diagnostics() async throws -> DiagnosticsSnapshot {
        try await call("GET", "api/v1/diagnostics", expecting: 200)
    }
}
