import Foundation
import Observation
import SwiftUI

/// A recorded message waiting for its transcription; kept on this iPhone only (03_iOS/04_Audio_Transcription.md).
nonisolated struct VoiceDraft: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        /// Stopped by an interruption: the user chooses Envoyer or Supprimer.
        case interrupted
        case ready
        case failed
    }

    let transcriptionId: String
    let fileName: String
    let durationMs: Int
    let createdAt: Date
    var state: State
    var errorCode: String?
}

/// Recording → Envoi → Transcription → message sent to the assistant with its transcription.
@Observable
final class VoiceMessageStore {
    enum Phase: Equatable {
        case idle
        case recording
        case uploading
        case transcribing
    }

    private(set) var phase: Phase = .idle
    private(set) var draft: VoiceDraft?
    var notice: String?
    var permissionDenied = false
    let recorder = VoiceRecorder()

    private let api: APIClient
    private let assistant: AssistantStore
    private let defaults = UserDefaults.standard
    private static let draftKey = "voice.draft"
    private static let maxAttempts = 3

    init(api: APIClient, assistant: AssistantStore) {
        self.api = api
        self.assistant = assistant
        if let data = defaults.data(forKey: Self.draftKey), let saved = try? JSONDecoder().decode(VoiceDraft.self, from: data) {
            draft = saved
        }
        Self.removeExpiredFiles(keeping: draft)
        if let draft, Date().timeIntervalSince(draft.createdAt) > 24 * 3600 {
            discard()
        }
        recorder.onAutomaticStop = { [weak self] outcome in
            self?.handle(outcome)
        }
    }

    // MARK: - Recording

    func startRecording() async {
        guard phase == .idle, draft == nil else { return }
        notice = nil
        switch VoiceRecorder.permission {
        case .denied:
            permissionDenied = true
            return
        case .undetermined:
            guard await VoiceRecorder.requestPermission() else {
                permissionDenied = true
                return
            }
        default:
            break
        }
        do {
            let url = try Self.directory().appending(path: "\(UUID().uuidString.lowercased()).m4a")
            try recorder.start(into: url)
            phase = .recording
        } catch {
            notice = "L’enregistrement n’a pas pu démarrer."
            phase = .idle
        }
    }

    func stopRecording() async {
        guard phase == .recording else { return }
        let outcome = await recorder.stop()
        handle(outcome)
    }

    func cancelRecording() {
        recorder.cancel()
        phase = .idle
    }

    /// The app leaves the foreground while recording.
    func appWillResignActive() async {
        guard phase == .recording else { return }
        await recorder.interrupt()
    }

    private func handle(_ outcome: VoiceRecorder.Outcome) {
        phase = .idle
        switch outcome {
        case .finished(let url, let durationMs):
            keep(url: url, durationMs: durationMs, state: .ready)
            Task { await send() }
        case .interrupted(let url, let durationMs):
            keep(url: url, durationMs: durationMs, state: .interrupted)
            notice = "Enregistrement interrompu."
        case .tooShortOrSilent:
            notice = "Aucun son détecté."
        case .failed:
            notice = "L’enregistrement a échoué."
        }
    }

    private func keep(url: URL, durationMs: Int, state: VoiceDraft.State) {
        Self.protect(url)
        save(VoiceDraft(
            transcriptionId: UUID().uuidString.lowercased(),
            fileName: url.lastPathComponent,
            durationMs: durationMs,
            createdAt: Date(),
            state: state
        ))
    }

    // MARK: - Transcription

    /// Upload, wait for the text, then send it as a voice message. The same identifier is reused on retry:
    /// a lost response never costs a second transcription.
    func send() async {
        guard var current = draft, phase == .idle else { return }
        guard assistant.pending == nil, !assistant.isBusy else {
            notice = "Une demande est déjà en cours. Le message vocal est gardé."
            return
        }
        notice = nil
        phase = .uploading
        do {
            var snapshot = try await api.uploadVoice(transcriptionId: current.transcriptionId, durationMs: current.durationMs, file: fileURL(current))
            phase = .transcribing
            while snapshot.status == "received" || snapshot.status == "transcribing" {
                try await Task.sleep(for: .seconds(2))
                snapshot = try await api.transcription(current.transcriptionId)
            }
            phase = .idle
            if snapshot.status == "completed", let text = snapshot.text {
                // The server keeps the text: the audio is no longer needed here.
                discard(abandonOnServer: false)
                await assistant.send(text: text, transcriptionId: snapshot.transcriptionId)
            } else {
                current.state = .failed
                current.errorCode = snapshot.errorCode
                save(current)
                notice = Self.failureText(snapshot.errorCode)
            }
        } catch let error as APIError {
            phase = .idle
            handle(error, draft: current)
        } catch {
            phase = .idle
            notice = "Envoi impossible pour le moment. Le message est gardé."
        }
    }

    /// "Écrire à la place" / "Supprimer": the file and the server's copy go away.
    func discard(abandonOnServer: Bool = true) {
        guard let current = draft else { return }
        try? FileManager.default.removeItem(at: fileURL(current))
        if abandonOnServer {
            let api = self.api
            Task { try? await api.abandonTranscription(current.transcriptionId) }
        }
        draft = nil
        defaults.removeObject(forKey: Self.draftKey)
    }

    var canRetry: Bool {
        draft?.errorCode.map { !Self.permanentCodes.contains($0) } ?? true
    }

    private func handle(_ error: APIError, draft current: VoiceDraft) {
        switch error {
        case .transport:
            notice = "Pas de réseau : le message vocal est gardé. Envoyez-le quand la connexion revient."
        case .http(503, _, _, _, _, _):
            notice = "La voix n’est pas configurée sur le serveur. Le message est gardé."
        case .http(_, let code, let retryAfter, _, _, _):
            let code = code ?? "UNKNOWN"
            if Self.permanentCodes.contains(code) {
                var failed = current
                failed.state = .failed
                failed.errorCode = code
                save(failed)
            }
            notice = code == "RATE_LIMITED"
                ? "Trop de messages vocaux cette heure-ci. Réessayez dans \(max(1, Int(((retryAfter ?? 60) / 60).rounded(.up)))) min."
                : Self.failureText(code)
        case .unauthorized:
            notice = "Cet iPhone n’est plus autorisé : voir Réglages."
        case .invalidResponse:
            notice = "Réponse inattendue du serveur. Le message est gardé."
        }
    }

    private func save(_ value: VoiceDraft) {
        draft = value
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Self.draftKey) }
    }

    private func fileURL(_ value: VoiceDraft) -> URL {
        (try? Self.directory().appending(path: value.fileName)) ?? URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: value.fileName)
    }

    // MARK: - Files

    /// Application Support/PendingAudio: not purgeable, excluded from backups, readable after first unlock.
    private static func directory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var url = base.appending(path: "PendingAudio", directoryHint: .isDirectory)
        if !FileManager.default.fileExists(atPath: url.path()) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
            ])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
        return url
    }

    private static func protect(_ url: URL) {
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path())
    }

    /// Files older than 24 h or not referenced by the current draft (a crash while recording).
    private static func removeExpiredFiles(keeping draft: VoiceDraft?) {
        guard let directory = try? directory(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path()) else { return }
        for name in names where name != draft?.fileName {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }

    // MARK: - Texts

    private static let permanentCodes: Set<String> = [
        "TRANSCRIPTION_FAILED", "TRANSCRIPTION_ABANDONED", "TRANSCRIPTION_ERASED", "AUDIO_INVALID", "AUDIO_TOO_SHORT",
        "AUDIO_TOO_LONG", "AUDIO_NOT_MONO", "AUDIO_DURATION_MISMATCH", "AUDIO_TOO_LARGE", "EMPTY_TRANSCRIPT",
        "TRANSCRIPTION_REJECTED", "IDEMPOTENCY_KEY_REUSED",
    ]

    private static func failureText(_ code: String?) -> String {
        switch code ?? "" {
        case "EMPTY_TRANSCRIPT": "Aucune parole reconnue. Réenregistrez ou écrivez le message."
        case "TRANSCRIPTION_FAILED": "La transcription a échoué trois fois. Écrivez le message à la place."
        case "TRANSCRIPTION_TIMEOUT", "TRANSCRIPTION_UNAVAILABLE", "INTERRUPTED", "INTERNAL_ERROR":
            "La transcription n’a pas abouti. Vous pouvez réessayer."
        case "TRANSCRIPTION_BUDGET_EXCEEDED": "Limite mensuelle de transcription atteinte. Écrivez le message."
        case "AUDIO_TOO_SHORT": "Enregistrement trop court."
        case "AUDIO_TOO_LONG": "Enregistrement trop long (2 minutes au plus)."
        case "AUDIO_TOO_LARGE": "Fichier audio trop volumineux."
        case let other where other.hasPrefix("AUDIO_"): "Fichier audio refusé. Réenregistrez le message."
        default: "La transcription n’a pas abouti (\(code ?? "erreur inconnue"))."
        }
    }
}
