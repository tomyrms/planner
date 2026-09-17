import Foundation
import Testing
@testable import Planner

/// Real voice recovery state machine with an isolated preferences suite and no network/provider.
@MainActor
struct VoiceMessageStoreTests {
    private static let transcriptionId = "11111111-1111-4111-8111-111111111111"
    private static let conversationId = "22222222-2222-4222-8222-222222222222"
    private static let audioFileName = "mémo vocal 01.m4a"

    @Test func recoverySuspensionPreservesAudioAndPendingIdentifierWithoutFurtherRequests() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let api = FakeVoiceAPI(reads: [])
        let assistant = FakeVoiceAssistant()
        let saved = draft(state: .pending)
        try fixture.seed(saved)
        let store = fixture.store(api, assistant)
        defer { store.stop() }
        try await store.suspendPreservingDraft()
        await store.appDidBecomeActive()
        await store.send()
        await store.verify()
        #expect(store.draft == saved)
        #expect(FileManager.default.fileExists(atPath: fixture.audio.path(percentEncoded: false)))
        let persistedData = try #require(fixture.defaults.data(forKey: "voice.draft"))
        let persisted = try JSONDecoder().decode(VoiceDraft.self, from: persistedData)
        #expect(persisted == saved)
        #expect(await api.calls.isEmpty)
        #expect(assistant.accepted.isEmpty)
    }

    @Test func recoveryWaitsForAudioFinalizationBeforeFreezingItsDraft() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let api = FakeVoiceAPI(reads: [])
        let assistant = FakeVoiceAssistant()
        let recorder = FakeVoiceRecorder()
        recorder.delayFinish = true
        let store = VoiceMessageStore(api: api, assistant: assistant, defaults: fixture.defaults,
                                      audioDirectory: fixture.directory, recorder: recorder,
                                      requestRecordingPermission: { true })
        defer { store.stop() }
        let started = await store.startRecording()
        #expect(started)
        let suspension = Task { try await store.suspendPreservingDraft() }
        await recorder.waitUntilFinishing()
        #expect(store.phase == .finishing)
        recorder.finishNow()
        try await suspension.value
        let saved = try #require(store.draft)
        #expect(saved.state == .interrupted)
        #expect(saved.conversationId == assistant.conversationId)
        #expect(FileManager.default.fileExists(atPath: fixture.directory.appending(path: saved.fileName).path(percentEncoded: false)))
        await store.send()
        #expect(await api.calls.isEmpty)
    }

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
        #expect(FileManager.default.fileExists(atPath: fixture.audio.path(percentEncoded: false)))
        await store.verify()

        #expect(await api.calls == ["GET", "POST", "GET"])
        #expect(assistant.accepted.count == 1)
        #expect(store.draft == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.audio.path(percentEncoded: false)))
    }

    @Test(arguments: [true, false])
    func oldMissingFileFailureCanRetryOnlyWhenTheAudioActuallyExists(_ fileExists: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var saved = draft(state: .failed)
        saved.errorCode = "AUDIO_FILE_MISSING"
        try fixture.seed(saved)
        if !fileExists { try FileManager.default.removeItem(at: fixture.audio) }
        let api = FakeVoiceAPI(
            reads: [.failure(.http(status: 404, code: "TRANSCRIPTION_NOT_FOUND", retryAfter: nil, serverGeneration: nil, minimumVersion: nil, message: nil))],
            upload: .success(snapshot("completed", text: "Le vocal déjà enregistré est récupéré"))
        )
        let assistant = FakeVoiceAssistant()
        let store = fixture.store(api, assistant)
        defer { store.stop() }

        #expect(store.canRetry == fileExists)
        let restoredData = try #require(fixture.defaults.data(forKey: "voice.draft"))
        let restored = try JSONDecoder().decode(VoiceDraft.self, from: restoredData)
        #expect(restored.errorCode == (fileExists ? nil : "AUDIO_FILE_MISSING"))
        #expect(restored.transcriptionId == saved.transcriptionId)
        await store.send()

        if fileExists {
            #expect(await api.calls == ["GET", "POST"])
            #expect(assistant.accepted.first?.transcriptionId == saved.transcriptionId)
            #expect(assistant.accepted.first?.text == "Le vocal déjà enregistré est récupéré")
            #expect(store.draft == nil)
        } else {
            #expect(await api.calls == ["GET"])
            #expect(assistant.accepted.isEmpty)
            #expect(store.draft?.errorCode == "AUDIO_FILE_MISSING")
            #expect(!store.canRetry)
        }
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
        #expect(!FileManager.default.fileExists(atPath: fixture.audio.path(percentEncoded: false)))

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

        let expectedHandoff = try #require(saved.handoff)
        #expect(assistant.prepareCount == 0)
        #expect(assistant.accepted == [expectedHandoff])
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
        #expect(!FileManager.default.fileExists(atPath: fixture.audio.path(percentEncoded: false)))
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

    @Test func permissionGrantedAfterReleaseCannotStartRecording() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let api = FakeVoiceAPI(reads: [])
        let recorder = FakeVoiceRecorder()
        let permission = PermissionGate()
        let store = VoiceMessageStore(
            api: api, assistant: FakeVoiceAssistant(), defaults: fixture.defaults, audioDirectory: fixture.directory,
            recorder: recorder, requestRecordingPermission: { await permission.wait() }
        )
        defer { store.stop() }
        let start = Task { await store.startRecording() }
        await permission.waitUntilRequested()
        await store.stopRecording() // Finger released while permission was unresolved.
        permission.resolve(true)
        let started = await start.value

        #expect(!started)
        #expect(recorder.startCount == 0)
        #expect(store.phase == .idle)
        #expect(!store.isPreparingRecording)
        #expect(await api.calls.isEmpty)
    }

    @Test func stopKeepsADurableDraftWithoutCallingTheServer() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let api = FakeVoiceAPI(reads: [])
        let recorder = FakeVoiceRecorder()
        let store = VoiceMessageStore(
            api: api, assistant: FakeVoiceAssistant(), defaults: fixture.defaults, audioDirectory: fixture.directory,
            recorder: recorder, requestRecordingPermission: { true }
        )
        defer { store.stop() }
        let started = await store.startRecording()
        #expect(started)
        await store.stopRecording()

        let draft = try #require(store.draft)
        let data = try #require(fixture.defaults.data(forKey: "voice.draft"))
        let persisted = try JSONDecoder().decode(VoiceDraft.self, from: data)
        #expect(persisted == draft)
        #expect(draft.state == .ready)
        #expect(FileManager.default.fileExists(atPath: fixture.directory.appending(path: draft.fileName).path(percentEncoded: false)))
        #expect(await api.calls.isEmpty)
    }

    @Test func backgroundDuringFinalizationKeepsTheRecording() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let api = FakeVoiceAPI(reads: [])
        let recorder = FakeVoiceRecorder()
        recorder.delayFinish = true
        let store = VoiceMessageStore(
            api: api, assistant: FakeVoiceAssistant(), defaults: fixture.defaults, audioDirectory: fixture.directory,
            recorder: recorder, requestRecordingPermission: { true }
        )
        defer { store.stop() }
        _ = await store.startRecording()
        let finish = Task { await store.stopRecording() }
        await recorder.waitUntilFinishing()
        #expect(store.phase == .finishing)
        #expect(!recorder.isRecording)
        await store.appWillResignActive()
        recorder.finishNow()
        await finish.value

        let draft = try #require(store.draft)
        #expect(draft.state == .ready)
        #expect(FileManager.default.fileExists(atPath: fixture.directory.appending(path: draft.fileName).path(percentEncoded: false)))
        #expect(await api.calls.isEmpty)
    }

    @Test func existingDraftIsNeverReplacedByANewHold() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let saved = draft()
        try fixture.seed(saved)
        let recorder = FakeVoiceRecorder()
        let store = VoiceMessageStore(
            api: FakeVoiceAPI(reads: []), assistant: FakeVoiceAssistant(), defaults: fixture.defaults,
            audioDirectory: fixture.directory, recorder: recorder, requestRecordingPermission: { true }
        )
        defer { store.stop() }
        let started = await store.startRecording()
        #expect(!started)
        #expect(store.draft?.transcriptionId == saved.transcriptionId)
        #expect(recorder.startCount == 0)
    }

    private func draft(state: VoiceDraft.State = .ready) -> VoiceDraft {
        VoiceDraft(
            transcriptionId: Self.transcriptionId, fileName: Self.audioFileName, durationMs: 2500,
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
        let root: URL
        let directory: URL
        var audio: URL { directory.appending(path: VoiceMessageStoreTests.audioFileName) }

        init() throws {
            name = "voice-tests-" + UUID().uuidString
            defaults = try #require(UserDefaults(suiteName: name))
            root = URL.temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
            // Match the iPhone's real directory and exercise decoded filesystem paths on upload,
            // recovery and cleanup. Neither the directory nor the filename is URL-safe as written.
            directory = root.appending(path: "Application Support", directoryHint: .isDirectory)
                .appending(path: "PendingAudio", directoryHint: .isDirectory)
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
            try? FileManager.default.removeItem(at: root)
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

@MainActor
private final class PermissionGate {
    private var pending: CheckedContinuation<Bool, Never>?
    private var requested: CheckedContinuation<Void, Never>?

    func wait() async -> Bool {
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

    func resolve(_ allowed: Bool) {
        pending?.resume(returning: allowed)
        pending = nil
    }
}

@MainActor
private final class FakeVoiceRecorder: VoiceRecording {
    var isRecording = false
    var elapsed: TimeInterval = 2.5
    var levels: [Float] = [0.2, 0.5]
    var onAutomaticStop: ((VoiceRecorder.Outcome) -> Void)?
    var startCount = 0
    var delayFinish = false
    private var file: URL?
    private var pendingFinish: CheckedContinuation<Void, Never>?
    private var finishWaiter: CheckedContinuation<Void, Never>?

    func start(into url: URL) throws {
        try Data([0]).write(to: url)
        file = url
        isRecording = true
        startCount += 1
    }

    func stop() async -> VoiceRecorder.Outcome {
        guard let file else { return .failed }
        isRecording = false
        if delayFinish {
            await withCheckedContinuation { continuation in
                pendingFinish = continuation
                finishWaiter?.resume()
                finishWaiter = nil
            }
        }
        return .finished(file, durationMs: 2500)
    }

    func cancel() {
        isRecording = false
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
    }

    func interrupt() async {
        let completion = onAutomaticStop
        let outcome = await stop()
        if case .finished(let url, let durationMs) = outcome {
            completion?(.interrupted(url, durationMs: durationMs))
        }
    }

    func waitUntilFinishing() async {
        if pendingFinish != nil { return }
        await withCheckedContinuation { finishWaiter = $0 }
    }

    func finishNow() {
        pendingFinish?.resume()
        pendingFinish = nil
    }
}
