import Foundation
import Testing
@testable import Planner

/// Real voice recovery state machine with an isolated preferences suite and no network/provider.
@MainActor
struct VoiceMessageStoreTests {
    private static let transcriptionId = "11111111-1111-4111-8111-111111111111"
    private static let conversationId = "22222222-2222-4222-8222-222222222222"

    @Test func lostUploadResponseIsRecoveredByReadingWithoutUploadingAgain() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let api = FakeVoiceAPI(
            reads: [.failure(.http(status: 404, code: "TRANSCRIPTION_NOT_FOUND", retryAfter: nil, serverGeneration: nil, minimumVersion: nil, message: nil)),
                    .success(snapshot("completed", text: "Appeler le garage demain"))],
            upload: .failure(.transport(.networkConnectionLost))
        )
        let assistant = FakeVoiceAssistant()
        try fixture.seed(draft())
        let store = fixture.store(api, assistant)
        defer { store.stop() }

        await store.send()
        #expect(store.draft?.state == .pending)
        #expect(FileManager.default.fileExists(atPath: fixture.audio.path()))
        await store.verify()

        #expect(await api.calls == ["GET", "POST", "GET"])
        #expect(assistant.accepted.count == 1)
        #expect(store.draft == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.audio.path()))
    }

    @Test func busyAssistantKeepsTranscriptAndOriginalConversationUntilAdmission() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let api = FakeVoiceAPI(reads: [.success(snapshot("completed", text: "Une demande à garder"))])
        let assistant = FakeVoiceAssistant()
        assistant.canAcceptVoice = false
        try fixture.seed(draft())
        let store = fixture.store(api, assistant)
        defer { store.stop() }

        await store.send()
        #expect(store.draft?.transcript == "Une demande à garder")
        #expect(store.draft?.state == .transcribed)
        #expect(assistant.accepted.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.audio.path()))

        assistant.canAcceptVoice = true
        assistant.onAccept = { turn in
            let data = try #require(fixture.defaults.data(forKey: "voice.draft"))
            let persisted = try JSONDecoder().decode(VoiceDraft.self, from: data)
            #expect(persisted.handoff == turn)
            #expect(persisted.transcript == turn.text)
        }
        await store.send()

        #expect(assistant.accepted.first?.conversationId == Self.conversationId)
        #expect(assistant.accepted.first?.text == "Une demande à garder")
        #expect(await api.calls == ["GET"])
        #expect(store.draft == nil)
    }

    @Test func persistedHandoffReplaysExactlyAfterAStopBetweenStores() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let api = FakeVoiceAPI(reads: [])
        let assistant = FakeVoiceAssistant()
        var saved = draft()
        saved.state = .transcribed
        saved.transcript = "Déplacer cette tâche"
        saved.handoff = PendingTurn(
            turnId: "33333333-3333-4333-8333-333333333333", conversationId: Self.conversationId,
            messageId: "44444444-4444-4444-8444-444444444444", text: "Déplacer cette tâche",
            transcriptionId: Self.transcriptionId, revisesMessageId: nil,
            referenceInstant: "2026-09-17T10:00:00.000Z", timeZone: "Europe/Zurich",
            unsyncedAggregateIds: ["55555555-5555-4555-8555-555555555555"]
        )
        try fixture.seed(saved)
        let store = fixture.store(api, assistant)
        defer { store.stop() }

        await store.appDidBecomeActive()

        #expect(assistant.prepareCount == 0)
        #expect(assistant.accepted == [try #require(saved.handoff)])
        #expect(await api.calls.isEmpty)
        #expect(store.draft == nil)
    }

    @Test func endlessServerProcessingReturnsToAnActionableState() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let api = FakeVoiceAPI(reads: [.success(snapshot("transcribing"))])
        let assistant = FakeVoiceAssistant()
        try fixture.seed(draft(state: .pending))
        let store = fixture.store(api, assistant, timeout: .zero)
        defer { store.stop() }

        await store.verify()

        #expect(store.phase == .idle)
        #expect(store.draft?.state == .pending)
        #expect(store.notice?.contains("plus de temps") == true)
        #expect(assistant.accepted.isEmpty)
        #expect(await api.calls == ["GET"])
    }

    @Test func foregroundRecoveryNeverRetriesAFailedProviderCall() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let api = FakeVoiceAPI(reads: [.success(snapshot("failed", error: "TRANSCRIPTION_TIMEOUT"))])
        let assistant = FakeVoiceAssistant()
        try fixture.seed(draft(state: .pending))
        let store = fixture.store(api, assistant)
        defer { store.stop() }

        await store.appDidBecomeActive()

        #expect(store.draft?.state == .failed)
        #expect(store.canRetry)
        #expect(await api.calls == ["GET"])
    }

    @Test func pausingIgnoresALateSuccessfulResponse() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let api = FakeVoiceAPI(reads: [], holdRead: true)
        let assistant = FakeVoiceAssistant()
        try fixture.seed(draft(state: .pending))
        let store = fixture.store(api, assistant)
        defer { store.stop() }
        let wait = Task { await store.verify() }
        await api.waitForRead()

        store.pause()
        await api.releaseRead(snapshot("completed", text: "Une réponse tardive"))
        await wait.value

        #expect(store.phase == .idle)
        #expect(store.draft?.state == .pending)
        #expect(store.draft?.transcript == nil)
        #expect(assistant.accepted.isEmpty)
    }

    @Test func logoutStopsTheOperationAndRemovesLocalAudio() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let api = FakeVoiceAPI(reads: [], holdRead: true)
        let assistant = FakeVoiceAssistant()
        try fixture.seed(draft(state: .pending))
        let store = fixture.store(api, assistant)
        let wait = Task { await store.verify() }
        await api.waitForRead()

        store.stop()
        await api.releaseRead(snapshot("completed", text: "Ne pas envoyer après déconnexion"))
        await wait.value
        await store.appDidBecomeActive()

        #expect(store.draft == nil)
        #expect(fixture.defaults.data(forKey: "voice.draft") == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.audio.path()))
        #expect(assistant.accepted.isEmpty)
        #expect(await api.calls == ["GET"])
    }

    @Test func oldDraftWithoutAddedFieldsStillRecovers() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.seed(draft())
        let data = try #require(fixture.defaults.data(forKey: "voice.draft"))
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "conversationId")
        object.removeValue(forKey: "transcript")
        object.removeValue(forKey: "handoff")
        fixture.defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: "voice.draft")
        let api = FakeVoiceAPI(reads: [.success(snapshot("completed", text: "Ancien brouillon"))])
        let assistant = FakeVoiceAssistant()
        let store = fixture.store(api, assistant)
        defer { store.stop() }

        await store.send()

        #expect(assistant.accepted.first?.conversationId == assistant.conversationId)
        #expect(assistant.accepted.first?.text == "Ancien brouillon")
        #expect(await api.calls == ["GET"])
    }

    private func draft(state: VoiceDraft.State = .ready) -> VoiceDraft {
        VoiceDraft(
            transcriptionId: Self.transcriptionId, fileName: "message.m4a", durationMs: 2500,
            createdAt: Date(), state: state, conversationId: Self.conversationId
        )
    }

    private func snapshot(_ status: String, text: String? = nil, error: String? = nil) -> TranscriptionSnapshot {
        TranscriptionSnapshot(transcriptionId: Self.transcriptionId, status: status, text: text, errorCode: error)
    }

    @MainActor
    private struct Fixture {
        let name: String
        let defaults: UserDefaults
        let directory: URL
        var audio: URL { directory.appending(path: "message.m4a") }

        init() throws {
            name = "voice-tests-" + UUID().uuidString
            defaults = try #require(UserDefaults(suiteName: name))
            directory = URL.temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func seed(_ draft: VoiceDraft) throws {
            defaults.set(try JSONEncoder().encode(draft), forKey: "voice.draft")
            try Data([0]).write(to: audio)
        }

        func store(_ api: FakeVoiceAPI, _ assistant: FakeVoiceAssistant, timeout: Duration = .seconds(75)) -> VoiceMessageStore {
            VoiceMessageStore(api: api, assistant: assistant, defaults: defaults, audioDirectory: directory, pollingTimeout: timeout)
        }

        func remove() {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

private actor FakeVoiceAPI: VoiceTranscriptionAPI {
    private var reads: [Result<TranscriptionSnapshot, APIError>]
    private let upload: Result<TranscriptionSnapshot, APIError>
    private let holdRead: Bool
    private var blockedRead: CheckedContinuation<TranscriptionSnapshot, Never>?
    private var readWaiter: CheckedContinuation<Void, Never>?
    private(set) var calls: [String] = []

    init(
        reads: [Result<TranscriptionSnapshot, APIError>],
        upload: Result<TranscriptionSnapshot, APIError> = .failure(.invalidResponse),
        holdRead: Bool = false
    ) {
        self.reads = reads
        self.upload = upload
        self.holdRead = holdRead
    }

    func transcription(_ id: String) async throws -> TranscriptionSnapshot {
        calls.append("GET")
        if holdRead {
            return await withCheckedContinuation { continuation in
                blockedRead = continuation
                readWaiter?.resume()
                readWaiter = nil
            }
        }
        guard !reads.isEmpty else { throw APIError.invalidResponse }
        return try reads.removeFirst().get()
    }

    func uploadVoice(transcriptionId: String, durationMs: Int, file: URL) async throws -> TranscriptionSnapshot {
        calls.append("POST")
        return try upload.get()
    }

    func abandonTranscription(_ id: String) async throws {
        calls.append("DELETE")
    }

    func waitForRead() async {
        if blockedRead != nil { return }
        await withCheckedContinuation { readWaiter = $0 }
    }

    func releaseRead(_ value: TranscriptionSnapshot) {
        blockedRead?.resume(returning: value)
        blockedRead = nil
    }
}

@MainActor
private final class FakeVoiceAssistant: VoiceAssistant {
    var conversationId = "66666666-6666-4666-8666-666666666666"
    var canAcceptVoice = true
    var onAccept: ((PendingTurn) throws -> Void)?
    private(set) var accepted: [PendingTurn] = []
    private(set) var prepareCount = 0

    func prepareVoiceTurn(text: String, transcriptionId: String, conversationId: String) async -> PendingTurn? {
        guard canAcceptVoice else { return nil }
        prepareCount += 1
        return PendingTurn(
            turnId: UUID().uuidString.lowercased(), conversationId: conversationId,
            messageId: UUID().uuidString.lowercased(), text: text, transcriptionId: transcriptionId,
            revisesMessageId: nil, referenceInstant: "2026-09-17T10:00:00.000Z",
            timeZone: "Europe/Zurich", unsyncedAggregateIds: []
        )
    }

    func acceptVoice(_ turn: PendingTurn) throws -> Bool {
        guard canAcceptVoice else { return false }
        try onAccept?(turn)
        accepted.append(turn)
        return true
    }
}
