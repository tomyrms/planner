import Foundation
import PowerSync
import Testing
@testable import Planner

/// Exercises the real AssistantStore with isolated preferences and its real local SQLite repository.
/// No request is made: failures enter at the same method used by HTTP submission.
@MainActor
struct AssistantRecoveryTests {
    @Test(arguments: [400, 401, 403, 409, 422, 426, 429])
    func refusalKeepsTheVoiceRequestAndAnExistingComposer(_ status: Int) async throws {
        try await withFixture { fixture in
            let error: APIError = status == 401 ? .unauthorized(code: "DEVICE_REVOKED")
                : .http(status: status, code: "REQUEST_REFUSED", retryAfter: nil, serverGeneration: nil, minimumVersion: nil, message: nil)
            fixture.store.handleSubmissionFailure(error, for: fixture.original)

            #expect(fixture.store.phase == .refused)
            #expect(fixture.store.pending == fixture.original)
            #expect(fixture.store.draft == fixture.existingDraft)
            let persisted = try fixture.persistedPending()
            #expect(persisted == fixture.original)
            #expect(fixture.store.entries.last?.message.text == fixture.original.text)
        }
    }

    @Test(arguments: [408, 500, 502, 503, 504])
    func serverFailureKeepsAnUnknownOutcomeUntilRead(_ status: Int) async throws {
        try await withFixture { fixture in
            fixture.store.handleSubmissionFailure(
                .http(status: status, code: "UPSTREAM_FAILURE", retryAfter: nil, serverGeneration: nil, minimumVersion: nil, message: nil),
                for: fixture.original
            )

            #expect(fixture.store.phase == .unknown)
            #expect(fixture.store.pending == fixture.original)
            let persisted = try fixture.persistedPending()
            #expect(persisted == fixture.original)
            fixture.store.discardPending()
            #expect(fixture.store.pending == fixture.original)
            #expect(fixture.store.draft == fixture.existingDraft)
        }
    }

    @Test func expiredTranscriptPersistsItsTextReplacementBeforeAnyTaskRuns() async throws {
        try await withFixture { fixture in
            fixture.store.handleSubmissionFailure(
                .http(status: 422, code: "TRANSCRIPTION_UNKNOWN", retryAfter: nil, serverGeneration: nil, minimumVersion: nil, message: nil),
                for: fixture.original
            )
            // There has been no suspension point since the error. A killed app must already have
            // everything it needs, before the task has even had a chance to call submit().
            let replacement = try #require(fixture.store.pending)
            fixture.store.stopRequests()
            let persisted = try fixture.persistedPending()
            #expect(persisted == replacement)
            #expect(replacement.turnId != fixture.original.turnId)
            #expect(replacement.messageId != fixture.original.messageId)
            #expect(replacement.transcriptionId == nil)
            #expect(replacement.text == fixture.original.text)
            #expect(replacement.conversationId == fixture.original.conversationId)
            #expect(replacement.referenceInstant == fixture.original.referenceInstant)
            #expect(replacement.timeZone == fixture.original.timeZone)
            #expect(replacement.unsyncedAggregateIds == fixture.original.unsyncedAggregateIds)
            #expect(fixture.store.draft == fixture.existingDraft)

            let relaunched = fixture.makeStore()
            #expect(relaunched.pending == replacement)
            #expect(relaunched.phase == .unknown)
            relaunched.stopRequests()
        }
    }

    @Test func editingARefusedVoiceCombinesBothTextsVisiblyAndPersistsThem() async throws {
        try await withFixture { fixture in
            fixture.store.handleSubmissionFailure(
                .http(status: 429, code: "RATE_LIMITED", retryAfter: 60, serverGeneration: nil, minimumVersion: nil, message: nil),
                for: fixture.original
            )
            fixture.store.discardPending()

            let expected = fixture.existingDraft + "\n\n" + fixture.original.text
            #expect(fixture.store.pending == nil)
            #expect(fixture.store.draft == expected)
            #expect(fixture.store.notice?.contains("deux paragraphes") == true)
            #expect(fixture.defaults.string(forKey: "assistant.draft") == expected)
            #expect(fixture.defaults.data(forKey: "assistant.pending") == nil)
            let relaunched = fixture.makeStore()
            #expect(relaunched.draft == expected)
            relaunched.stopRequests()
        }
    }

    @Test func stoppingKeepsRecoveryButSuccessfulUnpairClearsThePairingState() async throws {
        try await withFixture { fixture in
            fixture.store.stopRequests()
            let persisted = try fixture.persistedPending()
            #expect(persisted == fixture.original)
            #expect(fixture.defaults.string(forKey: "assistant.draft") == fixture.existingDraft)

            fixture.store.clearPairingState()
            #expect(fixture.defaults.data(forKey: "assistant.pending") == nil)
            #expect(fixture.defaults.string(forKey: "assistant.draft") == nil)
            #expect(fixture.defaults.string(forKey: "assistant.conversation") == nil)
            #expect(fixture.store.pending == nil)
            #expect(fixture.store.entries.isEmpty)
        }
    }

    @Test func combinedDraftAboveTheRequestLimitIsKeptInsteadOfTruncated() async throws {
        try await withFixture { fixture in
            fixture.store.draft = String(repeating: "a", count: 4000)
            fixture.store.handleSubmissionFailure(.unauthorized(code: nil), for: fixture.original)
            fixture.store.discardPending()
            let combined = fixture.store.draft

            await fixture.store.send()

            #expect(fixture.store.pending == nil)
            #expect(fixture.store.draft == combined)
            #expect(combined.hasSuffix(fixture.original.text))
            #expect(fixture.store.notice?.contains("4 000") == true)
        }
    }

    @Test func oversizedVoiceIsAdmittedDurablyForEditingWithoutUploading() async throws {
        try await withFixture { fixture in
            fixture.store.handleSubmissionFailure(.unauthorized(code: nil), for: fixture.original)
            fixture.store.discardPending()
            let original = fixture.original
            let longVoice = PendingTurn(
                turnId: UUID().uuidString.lowercased(), conversationId: original.conversationId,
                messageId: UUID().uuidString.lowercased(), text: String(repeating: "é", count: 4001),
                transcriptionId: original.transcriptionId, revisesMessageId: nil,
                referenceInstant: original.referenceInstant, timeZone: original.timeZone,
                unsyncedAggregateIds: original.unsyncedAggregateIds
            )
            let accepted = try fixture.store.acceptVoice(longVoice)
            #expect(accepted)
            #expect(fixture.store.phase == .refused)
            let persisted = try fixture.persistedPending()
            #expect(persisted == longVoice)
            #expect(fixture.store.pending?.text.count == 4001)
        }
    }

    private func withFixture(_ work: @MainActor (Fixture) async throws -> Void) async throws {
        let fixture = try Fixture()
        do {
            try await work(fixture)
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }

    @MainActor
    private final class Fixture {
        let name = "assistant-recovery-" + UUID().uuidString
        let defaults: UserDefaults
        let api: APIClient
        let repository: AssistantRepository
        let original: PendingTurn
        let existingDraft = "Un autre message commencé avant le vocal."
        let store: AssistantStore

        init() throws {
            defaults = try #require(UserDefaults(suiteName: name))
            original = PendingTurn(
                turnId: "11111111-1111-4111-8111-111111111111",
                conversationId: "22222222-2222-4222-8222-222222222222",
                messageId: "33333333-3333-4333-8333-333333333333",
                text: "Le vocal doit rester conservé, même en cas de refus.",
                transcriptionId: "44444444-4444-4444-8444-444444444444", revisesMessageId: nil,
                referenceInstant: "2026-09-17T10:00:00.000Z", timeZone: "Europe/Zurich",
                unsyncedAggregateIds: ["55555555-5555-4555-8555-555555555555"]
            )
            defaults.set(try JSONEncoder().encode(original), forKey: "assistant.pending")
            defaults.set(existingDraft, forKey: "assistant.draft")
            defaults.set(original.conversationId, forKey: "assistant.conversation")
            api = APIClient(
                session: StoredSession(
                    apiBaseURL: try #require(URL(string: "https://assistant-tests.invalid")),
                    deviceId: "test-device", refreshToken: "unused-test-token"
                ),
                clientVersion: "0.1.0", credentials: CredentialStore()
            )
            repository = AssistantRepository(db: LocalDatabase.open(fileName: name + ".sqlite"))
            store = AssistantStore(api: api, repository: repository, defaults: defaults)
        }

        func makeStore() -> AssistantStore {
            AssistantStore(api: api, repository: repository, defaults: defaults)
        }

        func persistedPending() throws -> PendingTurn {
            let data = try #require(defaults.data(forKey: "assistant.pending"))
            return try JSONDecoder().decode(PendingTurn.self, from: data)
        }

        func close() async {
            store.stopRequests()
            store.stop()
            try? await repository.db.disconnectAndClear()
            defaults.removePersistentDomain(forName: name)
        }
    }
}
