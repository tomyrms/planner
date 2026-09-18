import AVFAudio
import Foundation
import Observation
import SwiftUI

@MainActor
protocol VoiceRecording: AnyObject {
    var isRecording: Bool { get }
    var elapsed: TimeInterval { get }
    var levels: [Float] { get }
    var onAutomaticStop: ((VoiceRecorder.Outcome) -> Void)? { get set }
    func start(into url: URL) throws
    func stop() async -> VoiceRecorder.Outcome
    func cancel()
    func interrupt() async
}

extension VoiceRecorder: VoiceRecording {}

/// One recoverable voice message, scoped to the conversation in which recording started.
nonisolated struct VoiceDraft: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case interrupted, ready, failed, pending, transcribed
    }

    let transcriptionId: String
    let fileName: String
    let durationMs: Int
    let createdAt: Date
    var state: State
    var errorCode: String?
    // Optional additions preserve drafts written by earlier app versions.
    var conversationId: String? = nil
    var transcript: String? = nil
    /// Written before assistant admission: retries reuse the complete request after a crash.
    var handoff: PendingTurn? = nil
}

@Observable
final class VoiceMessageStore {
    enum Phase: Equatable {
        case idle, recording, finishing, checking, uploading, transcribing, delivering
    }

    private(set) var phase: Phase = .idle
    private(set) var draft: VoiceDraft?
    var notice: String?
    var permissionDenied = false
    let recorder: any VoiceRecording
    private(set) var isPreparingRecording = false

    private let api: any VoiceTranscriptionAPI
    private let assistant: any VoiceAssistant
    private let defaults: UserDefaults
    private let audioDirectory: URL
    private let pollingTimeout: Duration
    private let pollingInterval: Duration
    private let requestRecordingPermission: @MainActor () async -> Bool
    private static let draftKey = "voice.draft"
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var operationId: UUID?
    @ObservationIgnored private var expiry: Task<Void, Never>?
    @ObservationIgnored private var abandonments: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var recordingConversation: String?
    @ObservationIgnored private var recordingIntent: UUID?
    /// Release/send consent belongs to this recording, never to an older draft.
    @ObservationIgnored private var sendAfterRecordingIntent: UUID?
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var recoverySuspended = false

    init(
        api: any VoiceTranscriptionAPI, assistant: any VoiceAssistant,
        defaults: UserDefaults = .standard, audioDirectory: URL? = nil,
        suspended: Bool = false,
        pollingTimeout: Duration = .seconds(75), pollingInterval: Duration = .seconds(2),
        recorder: (any VoiceRecording)? = nil,
        requestRecordingPermission: @escaping @MainActor () async -> Bool = {
            switch VoiceRecorder.permission {
            case .granted: true
            case .undetermined: await VoiceRecorder.requestPermission()
            default: false
            }
        }
    ) {
        self.api = api
        self.assistant = assistant
        self.defaults = defaults
        self.recoverySuspended = suspended
        self.audioDirectory = audioDirectory ?? (try? Self.directory())
            ?? URL.temporaryDirectory.appending(path: "PendingAudio", directoryHint: .isDirectory)
        self.pollingTimeout = pollingTimeout
        self.pollingInterval = pollingInterval
        self.recorder = recorder ?? VoiceRecorder()
        self.requestRecordingPermission = requestRecordingPermission
        if let data = defaults.data(forKey: Self.draftKey),
           var saved = try? JSONDecoder().decode(VoiceDraft.self, from: data) {
            if saved.conversationId == nil { saved.conversationId = assistant.conversationId }
            draft = saved
        }
        removeUnreferencedFiles()
        recoverPreviouslyMissingAudio()
        if !expireIfNeeded() { scheduleExpiry() }
    }

    var isWorking: Bool { phase != .idle && phase != .recording }
    var canRetry: Bool {
        return draft?.errorCode.map { !Self.permanentCodes.contains($0) } ?? true
    }

    // MARK: - Recording

    @discardableResult
    func startRecording() async -> Bool {
        guard !stopped, !recoverySuspended, !Task.isCancelled, phase == .idle, recordingIntent == nil else { return false }
        guard draft == nil else {
            notice = "Un vocal est déjà conservé. Envoyez-le ou supprimez-le avant d’enregistrer."
            return false
        }
        guard assistant.canAcceptVoice else {
            notice = "Terminez la demande ou la correction en cours avant d’enregistrer."
            return false
        }
        let intent = UUID()
        recordingIntent = intent
        sendAfterRecordingIntent = nil
        notice = nil
        recordingConversation = assistant.conversationId
        isPreparingRecording = true
        let granted = await requestRecordingPermission()
        // Release/cancel may have invalidated this request or a newer recording may have started.
        guard recordingIntent == intent, !stopped else { return false }
        guard !Task.isCancelled else {
            cancelRecording()
            return false
        }
        isPreparingRecording = false
        guard granted else {
            permissionDenied = true
            cancelRecording()
            return false
        }
        phase = .recording
        recorder.onAutomaticStop = { [weak self] outcome in self?.handle(outcome, intent: intent) }
        do {
            try recorder.start(into: audioDirectory.appending(path: "\(UUID().uuidString.lowercased()).m4a"))
            return true
        } catch {
            cancelRecording()
            notice = "L’enregistrement n’a pas pu démarrer."
            return false
        }
    }

    func stopRecording() async {
        if isPreparingRecording { cancelRecording(); return }
        guard phase == .recording, recorder.isRecording, let intent = recordingIntent else { return }
        phase = .finishing
        let outcome = await recorder.stop()
        handle(outcome, intent: intent)
    }

    /// Hold release, locked arrow, or chat Send. Finalize and persist before admitting the store-owned
    /// operation; the caller can remove its recording controls without waiting for the network.
    func stopRecordingAndSend() async {
        guard !stopped, !recoverySuspended, !Task.isCancelled, phase == .recording,
              recorder.isRecording, draft == nil, let intent = recordingIntent else { return }
        sendAfterRecordingIntent = intent
        await stopRecording()
    }

    func cancelRecording() {
        sendAfterRecordingIntent = nil
        recordingConversation = nil
        recordingIntent = nil
        isPreparingRecording = false
        recorder.cancel()
        phase = .idle
    }

    func appWillResignActive() async {
        // Leaving the foreground during duration measurement keeps a draft, not an automatic send.
        sendAfterRecordingIntent = nil
        if isPreparingRecording {
            cancelRecording()
        } else if phase == .recording {
            if recorder.isRecording {
                phase = .finishing
                await recorder.interrupt()
            } else {
                // Automatic stop may already be measuring the finalized asset's duration.
                phase = .finishing
            }
        } else if phase != .finishing, isWorking {
            pause()
        }
    }

    /// Only reads on recovery: a failed transcription never causes another paid attempt by itself.
    func appDidBecomeActive() async {
        guard !stopped, !recoverySuspended, !expireIfNeeded(), let current = draft else { return }
        recoverPreviouslyMissingAudio()
        if current.state == .pending || current.transcript != nil || current.handoff != nil {
            await verify()
        }
    }

    private func handle(_ outcome: VoiceRecorder.Outcome, intent: UUID) {
        guard !stopped, recordingIntent == intent, let conversation = recordingConversation else {
            // Cancel/logout can win while AVURLAsset is measuring an already-finalized recording.
            switch outcome {
            case .finished(let url, _), .interrupted(let url, _):
                try? FileManager.default.removeItem(at: url)
            default:
                break
            }
            return
        }
        let shouldSend = sendAfterRecordingIntent == intent && !recoverySuspended && !Task.isCancelled
        sendAfterRecordingIntent = nil
        recordingConversation = nil
        recordingIntent = nil
        isPreparingRecording = false
        phase = .idle
        switch outcome {
        case .finished(let url, let durationMs):
            if keep(url: url, durationMs: durationMs, conversation: conversation, interrupted: false) {
                if shouldSend {
                    // No suspension between persistence and operation admission: a view observing
                    // .idle cannot substitute another draft or steal the explicit send decision.
                    _ = beginOperation(allowUpload: true)
                } else {
                    notice = "Vocal prêt à envoyer."
                }
            }
        case .interrupted(let url, let durationMs):
            if keep(url: url, durationMs: durationMs, conversation: conversation, interrupted: true) {
                notice = "Enregistrement interrompu."
            }
        case .tooShortOrSilent:
            notice = "Aucun son détecté."
        case .failed:
            notice = "L’enregistrement a échoué."
        }
    }

    private func keep(url: URL, durationMs: Int, conversation: String, interrupted: Bool) -> Bool {
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path(percentEncoded: false)
        )
        do {
            try save(VoiceDraft(
                transcriptionId: UUID().uuidString.lowercased(), fileName: url.lastPathComponent,
                durationMs: durationMs, createdAt: Date(), state: interrupted ? .interrupted : .ready,
                conversationId: conversation
            ))
            return true
        } catch {
            try? FileManager.default.removeItem(at: url)
            notice = "Le message vocal n’a pas pu être conservé."
            return false
        }
    }

    // MARK: - Owned operation and recovery

    func send() async {
        await beginOperation(allowUpload: true)?.value
    }

    func verify() async {
        await beginOperation(allowUpload: false)?.value
    }

    private func beginOperation(allowUpload: Bool) -> Task<Void, Never>? {
        guard !stopped, !recoverySuspended, phase == .idle, operation == nil, draft != nil, !expireIfNeeded() else { return nil }
        let id = UUID()
        operationId = id
        notice = nil
        phase = .checking
        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(id: id, allowUpload: allowUpload)
            if self.operationId == id {
                self.operation = nil
                self.operationId = nil
                self.phase = .idle
            }
        }
        operation = task
        return task
    }

    /// Pausing the wait does not claim that the server stopped its transcription.
    func pause() {
        sendAfterRecordingIntent = nil
        operation?.cancel()
        operation = nil
        operationId = nil
        phase = .idle
        notice = "Attente suspendue. Le serveur peut encore traiter le vocal. Vérifiez le résultat pour reprendre."
    }

    private func checkCurrent(_ id: UUID) throws {
        guard !stopped, operationId == id, !Task.isCancelled else { throw CancellationError() }
    }

    private func run(id: UUID, allowUpload: Bool) async {
        guard var current = draft else { return }
        do {
            if current.transcript != nil {
                try await deliver(&current, operationId: id)
                return
            }
            // Read first even on retry: a lost POST response may already have produced text.
            var snapshot: TranscriptionSnapshot?
            do {
                snapshot = try await api.transcription(current.transcriptionId)
                try checkCurrent(id)
            } catch APIError.http(404, _, _, _, _, _) {
                try checkCurrent(id)
            }
            let serverAllowsRetry = snapshot?.errorCode.map { !Self.permanentCodes.contains($0) } ?? true
            if snapshot == nil || (snapshot?.status == "failed" && allowUpload && canRetry && serverAllowsRetry) {
                guard allowUpload else {
                    current.state = .ready
                    current.errorCode = nil
                    try save(current)
                    notice = "Le serveur n’a pas reçu ce vocal. Vous pouvez l’envoyer."
                    return
                }
                guard FileManager.default.fileExists(atPath: fileURL(current).path(percentEncoded: false)) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                current.state = .pending
                current.errorCode = nil
                try save(current) // Before POST: recovery knows that the outcome may be unknown.
                phase = .uploading
                snapshot = try await api.uploadVoice(
                    transcriptionId: current.transcriptionId, durationMs: current.durationMs, file: fileURL(current)
                )
                try checkCurrent(id)
            }
            guard var result = snapshot, result.transcriptionId == current.transcriptionId else {
                throw APIError.invalidResponse
            }
            current.state = .pending
            try save(current)
            phase = .transcribing
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: pollingTimeout)
            while result.status == "received" || result.status == "transcribing" {
                guard clock.now < deadline else {
                    notice = "La transcription prend plus de temps que prévu. Le vocal est gardé : vérifiez le résultat."
                    return
                }
                try await Task.sleep(for: min(pollingInterval, clock.now.duration(to: deadline)))
                try checkCurrent(id)
                guard clock.now < deadline else { continue }
                result = try await api.transcription(current.transcriptionId)
                try checkCurrent(id)
                guard result.transcriptionId == current.transcriptionId else { throw APIError.invalidResponse }
            }
            switch result.status {
            case "completed":
                guard let text = result.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw APIError.invalidResponse
                }
                current.transcript = text
                current.state = .transcribed
                current.errorCode = nil
                try save(current) // Keep the text locally before deleting the now-unneeded audio.
                try? FileManager.default.removeItem(at: fileURL(current))
                try await deliver(&current, operationId: id)
            case "failed", "abandoned":
                current.state = .failed
                current.errorCode = result.status == "abandoned" ? "TRANSCRIPTION_ABANDONED" : result.errorCode
                try save(current)
                notice = Self.failureText(current.errorCode)
            default:
                throw APIError.invalidResponse
            }
        } catch {
            guard operationId == id, !Task.isCancelled, !stopped else { return }
            handle(error, current: draft ?? current)
        }
    }

    private func deliver(_ current: inout VoiceDraft, operationId: UUID) async throws {
        phase = .delivering
        if current.handoff == nil {
            guard let text = current.transcript,
                  let turn = await assistant.prepareVoiceTurn(
                    text: text, transcriptionId: current.transcriptionId,
                    conversationId: current.conversationId ?? assistant.conversationId
                  ) else {
                try checkCurrent(operationId)
                notice = "Texte transcrit conservé. Terminez la demande ou la correction en cours, puis envoyez-le."
                return
            }
            try checkCurrent(operationId)
            current.handoff = turn
            try save(current) // Stable IDs and body survive a crash between the two stores.
        }
        try checkCurrent(operationId)
        guard let turn = current.handoff, try assistant.acceptVoice(turn) else {
            notice = "Texte transcrit conservé. Une autre demande est en cours."
            return
        }
        // Admission acknowledged only after PendingTurn has been persisted. No await in this handoff.
        clearDraft()
    }

    /// Stops every task owned by the voice flow and erases this pairing's local audio.
    func stop() {
        stopped = true
        pause()
        cancelRecording()
        expiry?.cancel()
        for task in abandonments.values { task.cancel() }
        abandonments.removeAll()
        clearDraft()
    }

    /// Recovery freezes requests but must archive a recording that has already been captured.
    /// Let AVURLAsset finish before marking the store stopped, otherwise its callback deletes the file.
    func suspendPreservingDraft() async throws {
        recoverySuspended = true
        sendAfterRecordingIntent = nil
        if stopped { return }
        if phase != .recording && phase != .finishing { pause() }
        await appWillResignActive()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(15))
        while phase == .finishing {
            guard clock.now < deadline else { throw RecoveryError.recordingStillFinishing }
            try await Task.sleep(for: .milliseconds(50))
        }
        stopped = true
        for task in abandonments.values { task.cancel() }
        abandonments.removeAll()
        // The expiry task remains local: it may delete expired audio, never send another request.
    }

    /// Used only by freshly constructed services after the recovery journal has been completed.
    func activateRequests() {
        guard !stopped else { return }
        recoverySuspended = false
    }

    func discard() {
        pause()
        notice = nil
        if let current = draft { abandon(current.transcriptionId) }
        clearDraft()
    }

    private func clearDraft() {
        if let current = draft { try? FileManager.default.removeItem(at: fileURL(current)) }
        expiry?.cancel()
        expiry = nil
        draft = nil
        defaults.removeObject(forKey: Self.draftKey)
    }

    private func abandon(_ transcriptionId: String) {
        guard !stopped, !recoverySuspended else { return }
        let id = UUID()
        let api = self.api
        abandonments[id] = Task { [weak self] in
            try? await api.abandonTranscription(transcriptionId)
            self?.abandonments.removeValue(forKey: id)
        }
    }

    private func save(_ value: VoiceDraft) throws {
        let data = try JSONEncoder().encode(value)
        defaults.set(data, forKey: Self.draftKey)
        draft = value
        scheduleExpiry()
    }

    private func fileURL(_ value: VoiceDraft) -> URL { audioDirectory.appending(path: value.fileName) }

    /// Old builds marked existing files as missing by passing an encoded path to FileManager.
    /// Repair that persisted failure during restoration, never from SwiftUI's body.
    private func recoverPreviouslyMissingAudio() {
        guard var current = draft, current.errorCode == "AUDIO_FILE_MISSING",
              FileManager.default.fileExists(atPath: fileURL(current).path(percentEncoded: false)) else { return }
        current.errorCode = nil
        try? save(current)
        notice = "Le vocal enregistré est disponible. Vous pouvez réessayer."
    }

    // MARK: - Retention

    @discardableResult
    private func expireIfNeeded() -> Bool {
        guard let current = draft, current.transcript == nil,
              Date().timeIntervalSince(current.createdAt) >= 24 * 3600 else { return false }
        discard()
        notice = "Ce vocal a expiré après 24 h. Réenregistrez-le ou écrivez le message."
        return true
    }

    private func scheduleExpiry() {
        expiry?.cancel()
        guard let current = draft, current.transcript == nil else { return }
        let remaining = max(0, 24 * 3600 - Date().timeIntervalSince(current.createdAt))
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            self?.expireIfNeeded()
        }
    }

    private func removeUnreferencedFiles() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: audioDirectory.path(percentEncoded: false)) else { return }
        for name in names where name != draft?.fileName || draft?.transcript != nil {
            try? FileManager.default.removeItem(at: audioDirectory.appending(path: name))
        }
    }

    private static func directory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var url = base.appending(path: "PendingAudio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
        ])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        return url
    }

    // MARK: - Errors (no transcript or audio content in diagnostics)

    private func handle(_ error: any Error, current: VoiceDraft) {
        if let apiError = error as? APIError {
            switch apiError {
            case .transport(let code):
                notice = code == .timedOut
                    ? "Le serveur n’a pas répondu à temps. Vérifiez le résultat avant de réessayer. (URL \(code.rawValue))"
                    : "Connexion au serveur interrompue. Le vocal est gardé. (URL \(code.rawValue))"
            case .http(let status, let code, let retryAfter, _, _, _):
                var failed = current
                failed.state = .failed
                failed.errorCode = code
                try? save(failed)
                if code == "RATE_LIMITED" {
                    notice = "Trop de messages vocaux cette heure-ci. Réessayez dans \(max(1, Int(((retryAfter ?? 60) / 60).rounded(.up)))) min."
                } else if status == 503 {
                    notice = "Le service vocal est indisponible. Sa connexion ou sa configuration doit être vérifiée."
                } else {
                    notice = Self.failureText(code)
                }
                notice = (notice ?? "") + " (HTTP \(status)\(code.map { ", " + $0 } ?? ""))"
            case .unauthorized(let code):
                notice = "Cet iPhone n’est plus autorisé : voir Réglages. (\(code ?? "AUTH_REQUIRED"))"
            case .invalidResponse:
                notice = "Réponse inattendue du serveur. Le vocal est gardé. (INVALID_RESPONSE)"
            }
        } else if (error as? CocoaError)?.code == .fileNoSuchFile {
            var failed = current
            failed.state = .failed
            failed.errorCode = "AUDIO_FILE_MISSING"
            try? save(failed)
            notice = "Le fichier audio n’est plus disponible. Réenregistrez ou écrivez le message. (AUDIO_FILE_MISSING)"
        } else {
            notice = "Envoi impossible pour le moment. Le message est gardé."
        }
    }

    private static let permanentCodes: Set<String> = [
        "TRANSCRIPTION_FAILED", "TRANSCRIPTION_ABANDONED", "TRANSCRIPTION_ERASED", "AUDIO_INVALID", "AUDIO_TOO_SHORT",
        "AUDIO_TOO_LONG", "AUDIO_NOT_MONO", "AUDIO_DURATION_MISMATCH", "AUDIO_TOO_LARGE", "EMPTY_TRANSCRIPT",
        "TRANSCRIPTION_REJECTED", "IDEMPOTENCY_KEY_REUSED", "AUDIO_FILE_MISSING",
    ]

    private static func failureText(_ code: String?) -> String {
        switch code ?? "" {
        case "EMPTY_TRANSCRIPT": "Aucune parole reconnue. Réenregistrez ou écrivez le message."
        case "TRANSCRIPTION_FAILED": "La transcription a échoué trois fois. Écrivez le message à la place."
        case "TRANSCRIPTION_TIMEOUT", "TRANSCRIPTION_UNAVAILABLE", "INTERRUPTED", "INTERNAL_ERROR":
            "La transcription n’a pas abouti. Vous pouvez réessayer. (\(code ?? ""))"
        case "TRANSCRIPTION_BUDGET_EXCEEDED": "Limite mensuelle de transcription atteinte. Écrivez le message."
        case "AUDIO_TOO_SHORT": "Enregistrement trop court."
        case "AUDIO_TOO_LONG": "Enregistrement trop long (2 minutes au plus)."
        case "AUDIO_TOO_LARGE": "Fichier audio trop volumineux."
        case let other where other.hasPrefix("AUDIO_"): "Fichier audio refusé. Réenregistrez le message. (\(other))"
        default: "La transcription n’a pas abouti (\(code ?? "erreur inconnue"))."
        }
    }
}
