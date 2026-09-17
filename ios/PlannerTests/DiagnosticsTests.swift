import Foundation
import Testing
@testable import Planner

@MainActor
struct DiagnosticsTests {
    @Test func decodesTheRealAnonymousServerResponseShape() throws {
        let snapshot = try Self.snapshot()
        #expect(snapshot.generatedAt == "2026-09-17T10:00:00.000Z")
        #expect(snapshot.sync == .provisioned)
        #expect(snapshot.replicationLagBytes == nil)
        #expect(snapshot.assistant.status == .configured)
        #expect(snapshot.assistant.monthTokens == 1250)
        #expect(snapshot.transcription.status == .disabled)
        #expect(snapshot.transcription.provider == nil)
        #expect(snapshot.transcription.monthMinutes == 3.25)
        #expect(snapshot.maintenance.backup.lastFailedAt == nil)
        #expect(snapshot.maintenance.backupVerify.lastSucceededAt == nil)
        #expect(snapshot.maintenance.restore.lastSucceededAt == nil)
        #expect(snapshot.maintenance.audioCleanup.lastSucceededAt != nil)
    }

    @Test func laterFailureWinsOverAPastSuccessAndSuccessCanRecover() throws {
        let now = try #require(Timestamp.parse("2026-09-17T10:00:00Z"))
        let failed = DiagnosticsRun(lastSucceededAt: "2026-09-17T02:00:00Z", lastFailedAt: "2026-09-17T03:00:00Z")
        let recovered = DiagnosticsRun(lastSucceededAt: "2026-09-17T03:00:00Z", lastFailedAt: "2026-09-17T02:00:00Z")
        let equal = DiagnosticsRun(lastSucceededAt: "2026-09-17T03:00:00Z", lastFailedAt: "2026-09-17T03:00:00Z")
        #expect(failed.state(at: now, maximumAge: 86_400) == .failed)
        #expect(recovered.state(at: now, maximumAge: 86_400) == .succeeded)
        #expect(equal.state(at: now, maximumAge: 86_400) == .failed)
    }

    @Test func missingMalformedFutureAndOldDatesNeverBecomeRecentSuccess() throws {
        let now = try #require(Timestamp.parse("2026-09-17T10:00:00Z"))
        let unknown = DiagnosticsRun(lastSucceededAt: nil, lastFailedAt: nil)
        let malformed = DiagnosticsRun(lastSucceededAt: "not-a-date", lastFailedAt: nil)
        let malformedFailure = DiagnosticsRun(lastSucceededAt: "2026-09-17T02:00:00Z", lastFailedAt: "not-a-date")
        let future = DiagnosticsRun(lastSucceededAt: "2026-09-18T02:00:00Z", lastFailedAt: nil)
        let old = DiagnosticsRun(lastSucceededAt: "2026-09-16T09:59:59Z", lastFailedAt: nil)
        let hourly = DiagnosticsRun(lastSucceededAt: "2026-09-17T08:59:59Z", lastFailedAt: nil)
        #expect(unknown.state(at: now, maximumAge: 86_400) == .unknown)
        #expect(malformed.state(at: now, maximumAge: 86_400) == .inconsistent)
        #expect(malformedFailure.state(at: now, maximumAge: 86_400) == .inconsistent)
        #expect(future.state(at: now, maximumAge: 86_400) == .inconsistent)
        #expect(old.state(at: now, maximumAge: 86_400) == .stale)
        #expect(hourly.state(at: now, maximumAge: 3_600) == .stale)
        // A restoration is historical; it has no recurring deadline.
        #expect(old.state(at: now, maximumAge: nil) == .succeeded)
    }

    @Test func offlineRefreshRetainsTheDatedSnapshotAndRetryClearsTheError() async throws {
        let snapshot = try Self.snapshot()
        let store = DiagnosticsStore()
        await store.refresh(using: StubDiagnosticsAPI(result: .success(snapshot)))
        await store.refresh(using: StubDiagnosticsAPI(result: .failure(.transport(.notConnectedToInternet))))
        #expect(store.snapshot == snapshot)
        #expect(store.failure == .offline)
        #expect(!store.isLoading)
        await store.refresh(using: StubDiagnosticsAPI(result: .success(snapshot)))
        #expect(store.failure == nil)
        #expect(store.snapshot == snapshot)
    }

    @Test func serverErrorContentIsNeverUsedAsDisplayText() async {
        let store = DiagnosticsStore()
        let error = APIError.http(
            status: 503, code: "INTERNAL", retryAfter: nil, serverGeneration: nil,
            minimumVersion: nil, message: "private transcript and secret-token"
        )
        await store.refresh(using: StubDiagnosticsAPI(result: .failure(error)))
        #expect(store.failure == .unavailable)
        #expect(store.failure?.message.contains("private") == false)
        #expect(store.failure?.message.contains("secret-token") == false)
        #expect(store.snapshot == nil)
    }

    @Test func revokedDeviceAndInvalidSnapshotHaveActionableStates() async throws {
        let store = DiagnosticsStore()
        await store.refresh(using: StubDiagnosticsAPI(result: .failure(.unauthorized(code: "DEVICE_REVOKED"))))
        #expect(store.failure == .authorization)
        let invalid = try Self.snapshot(generatedAt: "invalid")
        await store.refresh(using: StubDiagnosticsAPI(result: .success(invalid)))
        #expect(store.failure == .invalidResponse)
        #expect(store.snapshot == nil)
    }

    @Test func aLateOlderReadCannotOverwriteANewerRefresh() async throws {
        let older = try Self.snapshot(generatedAt: "2026-09-16T10:00:00.000Z")
        let newer = try Self.snapshot()
        let gate = DelayedDiagnosticsAPI()
        let store = DiagnosticsStore()
        let first = Task { await store.refresh(using: gate) }
        await gate.waitUntilRequested()
        #expect(store.isLoading)
        await store.refresh(using: StubDiagnosticsAPI(result: .success(newer)))
        await gate.resolve(older)
        await first.value
        #expect(store.snapshot == newer)
        #expect(store.failure == nil)
        #expect(!store.isLoading)
    }

    @Test func leavingTheScreenIgnoresALateResponse() async throws {
        let snapshot = try Self.snapshot()
        let gate = DelayedDiagnosticsAPI()
        let store = DiagnosticsStore()
        let loading = Task { await store.refresh(using: gate) }
        await gate.waitUntilRequested()
        loading.cancel()
        store.cancel()
        await gate.resolve(snapshot)
        await loading.value
        #expect(store.snapshot == nil)
        #expect(store.failure == nil)
        #expect(!store.isLoading)
    }

    /// Mirrors tests/maintenance/diagnostics.test.ts, with fixed anonymous identifiers and no secrets.
    private static func snapshot(generatedAt: String = "2026-09-17T10:00:00.000Z") throws -> DiagnosticsSnapshot {
        let json = #"""
        {
          "generatedAt": "\#(generatedAt)",
          "serverGeneration": "11111111-1111-4111-8111-111111111111",
          "minimumClientVersion": "0.2.0",
          "sync": "provisioned",
          "replicationLagBytes": null,
          "assistant": { "status": "configured", "provider": "deepseek", "model": "deepseek-test", "monthTokens": 1250, "monthTokenBudget": 100000 },
          "transcription": { "status": "disabled", "provider": null, "model": null, "monthMinutes": 3.25, "monthMinuteBudget": 600 },
          "maintenance": {
            "backup": { "lastSucceededAt": "2026-09-17T02:00:00.000Z", "lastFailedAt": null },
            "backupVerify": { "lastSucceededAt": null, "lastFailedAt": "2026-09-17T02:05:00.000Z" },
            "restore": { "lastSucceededAt": null, "lastFailedAt": null },
            "purge": { "lastSucceededAt": "2026-09-16T12:00:00.000Z", "lastFailedAt": null },
            "audioCleanup": { "lastSucceededAt": "2026-09-17T09:30:00.000Z", "lastFailedAt": null }
          }
        }
        """#
        return try JSONDecoder().decode(DiagnosticsSnapshot.self, from: Data(json.utf8))
    }
}

private actor StubDiagnosticsAPI: DiagnosticsAPI {
    let result: Result<DiagnosticsSnapshot, APIError>
    init(result: Result<DiagnosticsSnapshot, APIError>) { self.result = result }
    func diagnostics() async throws -> DiagnosticsSnapshot { try result.get() }
}

private actor DelayedDiagnosticsAPI: DiagnosticsAPI {
    private var pending: CheckedContinuation<DiagnosticsSnapshot, Never>?
    private var requested: CheckedContinuation<Void, Never>?

    func diagnostics() async throws -> DiagnosticsSnapshot {
        await withCheckedContinuation { continuation in
            pending = continuation
            requested?.resume()
            requested = nil
        }
    }

    func waitUntilRequested() async {
        if pending != nil { return }
        await withCheckedContinuation { requested = $0 }
    }

    func resolve(_ snapshot: DiagnosticsSnapshot) {
        pending?.resume(returning: snapshot)
        pending = nil
    }
}
