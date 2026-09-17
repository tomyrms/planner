import Foundation
import Observation
import SwiftUI

/// A request sent but not yet answered; kept on disk so that a killed app can check the result
/// instead of sending the request again (02_Design/04_IA_Chat_UX.md, États d'un tour).
nonisolated struct PendingTurn: Codable, Equatable, Sendable {
    let turnId: String
    let conversationId: String
    let messageId: String
    let text: String
    let transcriptionId: String?
    let revisesMessageId: String?
    let referenceInstant: String
    let timeZone: String
    var unsyncedAggregateIds: [String]

    var request: TurnRequest {
        TurnRequest(
            turnId: turnId,
            conversationId: conversationId,
            message: .init(id: messageId, text: text, transcriptionId: transcriptionId, revisesMessageId: revisesMessageId),
            referenceInstant: referenceInstant,
            timeZone: timeZone,
            unsyncedAggregateIds: unsyncedAggregateIds
        )
    }
}

/// Preparing a turn has no remote effect. Admission persists it before acknowledging the voice draft.
@MainActor
protocol VoiceAssistant: AnyObject {
    var conversationId: String { get }
    var canAcceptVoice: Bool { get }
    func prepareVoiceTurn(text: String, transcriptionId: String, conversationId: String) async -> PendingTurn?
    func acceptVoice(_ turn: PendingTurn) throws -> Bool
}

/// One line of the conversation as shown, with what can be done on it.
struct ThreadEntry: Identifiable {
    let message: ThreadMessage
    /// Actions of the turn, on its last assistant message only.
    var controls: TurnControls?
    /// Touchable answers of the latest open question.
    var options: [String] = []
    /// The user's own text of the same turn ("Redemander").
    var requestText: String?
    var id: String { message.id }
}

@Observable
final class AssistantStore: VoiceAssistant {
    enum Phase: Equatable {
        case idle
        case preparing
        case waiting
        /// No answer: the request may have been processed. Only "Vérifier le résultat" is offered.
        case unknown
        /// The request never left the iPhone (offline): "Envoyer" sends the same request, explicitly.
        case offline
        /// The server has no trace of it.
        case notReceived
    }

    private(set) var conversationId: String
    private(set) var entries: [ThreadEntry] = []
    private(set) var phase: Phase = .idle
    private(set) var pending: PendingTurn?
    private(set) var busy: Set<String> = []
    private(set) var successCount = 0
    var draft: String {
        didSet { defaults.set(draft, forKey: Keys.draft) }
    }
    /// Message being corrected, and whether its effect must be undone first.
    private(set) var revising: (messageId: String, undoActionId: String?)?
    var notice: String?

    private let api: APIClient
    private let repository: AssistantRepository
    private let defaults = UserDefaults.standard
    private var messages: [ThreadMessage] = []
    private var turns: [String: TurnControls] = [:]
    private var snapshots: [String: TurnSnapshot] = [:]
    @ObservationIgnored private var observations: [Task<Void, Never>] = []
    @ObservationIgnored private var voiceSubmission: Task<Void, Never>?
    @ObservationIgnored private var expiredTranscriptSubmission: Task<Void, Never>?
    @ObservationIgnored private var requestsStopped = false
    /// Called when a turn changed something: reminders are reconciled at once, then again after replication.
    @ObservationIgnored var onResult: (() -> Void)?

    private enum Keys {
        static let draft = "assistant.draft"
        static let conversation = "assistant.conversation"
        static let pending = "assistant.pending"
    }

    init(api: APIClient, repository: AssistantRepository) {
        self.api = api
        self.repository = repository
        draft = defaults.string(forKey: Keys.draft) ?? ""
        conversationId = defaults.string(forKey: Keys.conversation) ?? UUID().uuidString.lowercased()
        if let data = defaults.data(forKey: Keys.pending), let saved = try? JSONDecoder().decode(PendingTurn.self, from: data) {
            pending = saved
            conversationId = saved.conversationId
            phase = .unknown
        }
    }

    var isBusy: Bool {
        phase == .preparing || phase == .waiting
    }

    var canSend: Bool {
        !requestsStopped && !isBusy && pending == nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canAcceptVoice: Bool { !requestsStopped && !isBusy && pending == nil && revising == nil }

    var isEmptyConversation: Bool {
        entries.isEmpty && pending == nil
    }

    // MARK: - Observation

    func start() {
        guard observations.isEmpty else { return }
        let repository = self.repository
        let conversationId = self.conversationId
        observations.append(Task { [weak self] in
            do {
                for try await rows in try repository.observeMessages(conversationId: conversationId) {
                    self?.messages = rows
                    self?.rebuild()
                }
            } catch {}
        })
        observations.append(Task { [weak self] in
            do {
                for try await rows in try repository.observeTurns(conversationId: conversationId) {
                    self?.turns = Dictionary(rows.map { ($0.turnId, $0) }, uniquingKeysWith: { first, _ in first })
                    self?.rebuild()
                }
            } catch {}
        })
    }

    func stop() {
        for observation in observations { observation.cancel() }
        observations.removeAll()
    }

    /// Called when the paired services are stopped, not when merely changing conversation.
    func stopRequests() {
        requestsStopped = true
        voiceSubmission?.cancel()
        voiceSubmission = nil
        expiredTranscriptSubmission?.cancel()
        expiredTranscriptSubmission = nil
    }

    /// Only after the database and Keychain pairing have both been removed successfully.
    /// A plain service stop keeps the pending request recoverable for the same pairing.
    func clearPairingState() {
        stopRequests()
        stop()
        pending = nil
        draft = ""
        revising = nil
        messages = []
        turns = [:]
        snapshots = [:]
        conversationId = UUID().uuidString.lowercased()
        phase = .idle
        for key in [Keys.pending, Keys.draft, Keys.conversation] { defaults.removeObject(forKey: key) }
        rebuild()
    }

    func open(conversation id: String) {
        guard !requestsStopped, pending == nil, !isBusy else {
            notice = "Une demande attend encore son résultat dans la conversation actuelle."
            return
        }
        stop()
        conversationId = id
        defaults.set(id, forKey: Keys.conversation)
        messages = []
        turns = [:]
        revising = nil
        rebuild()
        start()
    }

    func newConversation() {
        open(conversation: UUID().uuidString.lowercased())
    }

    // MARK: - Sending

    func prepareVoiceTurn(text: String, transcriptionId: String, conversationId: String) async -> PendingTurn? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canAcceptVoice, !text.isEmpty else { return nil }
        phase = .preparing
        defer { if phase == .preparing { phase = .idle } }
        let unsynced = await waitForLocalChanges()
        guard !Task.isCancelled, !requestsStopped else { return nil }
        return PendingTurn(
            turnId: UUID().uuidString.lowercased(), conversationId: conversationId,
            messageId: UUID().uuidString.lowercased(), text: String(text.prefix(4000)),
            transcriptionId: transcriptionId, revisesMessageId: nil,
            referenceInstant: Timestamp.format(Date()), timeZone: TimeZone.current.identifier,
            unsyncedAggregateIds: unsynced
        )
    }

    /// A crash between this write and clearing the vocal draft replays this exact request, including
    /// its timestamps and preconditions. The server's turn receipt prevents a second action.
    func acceptVoice(_ turn: PendingTurn) throws -> Bool {
        guard !requestsStopped else { return false }
        if pending == turn || snapshots[turn.turnId] != nil { return true }
        guard canAcceptVoice else { return false }
        let encoded = try JSONEncoder().encode(turn)
        if conversationId != turn.conversationId { open(conversation: turn.conversationId) }
        defaults.set(encoded, forKey: Keys.pending)
        pending = turn
        phase = .waiting
        rebuild()
        voiceSubmission = Task { [weak self] in
            guard let self else { return }
            await self.submit(turn)
            if !Task.isCancelled { self.voiceSubmission = nil }
        }
        return true
    }

    func send(text override: String? = nil, transcriptionId: String? = nil) async {
        let text = (override ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestsStopped, !text.isEmpty, !isBusy, pending == nil else { return }
        notice = nil
        phase = .preparing
        if let undoActionId = revising?.undoActionId {
            // "Annuler l'action et envoyer le texte corrigé": never a second silent creation.
            guard await undo(actionId: undoActionId) else {
                phase = .idle
                return
            }
        }
        let unsynced = await waitForLocalChanges()
        guard !Task.isCancelled, !requestsStopped else { return }
        let turn = PendingTurn(
            turnId: UUID().uuidString.lowercased(),
            conversationId: conversationId,
            messageId: UUID().uuidString.lowercased(),
            text: String(text.prefix(4000)),
            transcriptionId: transcriptionId,
            revisesMessageId: revising?.messageId,
            referenceInstant: Timestamp.format(Date()),
            timeZone: TimeZone.current.identifier,
            unsyncedAggregateIds: unsynced
        )
        remember(turn)
        if override == nil { draft = "" }
        revising = nil
        await submit(turn)
    }

    /// "Envoyer" after an offline failure or a lost request: the same identifiers, so never twice.
    func resend() async {
        guard !requestsStopped, let pending, !isBusy else { return }
        await submit(pending)
    }

    /// "Vérifier le résultat": reads the turn; never sends the request again by itself.
    func verify() async {
        guard !requestsStopped, let pending, !isBusy else { return }
        phase = .waiting
        do {
            let snapshot = try await api.turn(pending.turnId)
            guard !requestsStopped, !Task.isCancelled else { return }
            if snapshot.isFinished {
                accept(snapshot)
            } else {
                // Still running on the server: the request stays pending, to check again shortly.
                phase = .unknown
                notice = "L’assistant traite encore la demande. Vérifiez dans un instant."
            }
        } catch APIError.http(404, _, _, _, _, _) {
            guard !requestsStopped, !Task.isCancelled else { return }
            phase = .notReceived
        } catch {
            guard !requestsStopped, !Task.isCancelled else { return }
            phase = .unknown
            notice = "Résultat toujours inconnu : vérifiez la connexion."
        }
    }

    func cancelTurn() async {
        guard let pending else { return }
        _ = try? await api.cancelTurn(pending.turnId)
    }

    /// Gives up on a request the server never received; its text goes back to the composer.
    func discardPending() {
        guard let pending, phase == .notReceived || phase == .offline else { return }
        if draft.isEmpty { draft = pending.text }
        forget()
        phase = .idle
    }

    private func submit(_ turn: PendingTurn) async {
        phase = .waiting
        do {
            let snapshot = try await api.submitTurn(turn.request)
            guard !Task.isCancelled, !requestsStopped else { return }
            accept(snapshot)
            AccessibilityNotification.Announcement(Self.announcement(for: snapshot)).post()
        } catch let error as APIError {
            guard !Task.isCancelled, !requestsStopped else { return }
            handle(error, for: turn)
        } catch {
            guard !Task.isCancelled, !requestsStopped else { return }
            phase = .unknown
        }
    }

    private func accept(_ snapshot: TurnSnapshot) {
        snapshots[snapshot.turnId] = snapshot
        if !snapshot.results.isEmpty {
            successCount += 1
            onResult?()
        }
        forget()
        phase = .idle
        rebuild()
    }

    private func handle(_ error: APIError, for turn: PendingTurn) {
        switch error {
        case .transport(let code) where Self.neverSent.contains(code):
            phase = .offline
        case .transport, .invalidResponse:
            phase = .unknown
        case .http(_, .some("TRANSCRIPTION_UNKNOWN"), _, _, _, _) where turn.transcriptionId != nil:
            // The transcript was erased (unused for 24 h): the same text goes as a written message.
            forget()
            phase = .idle
            expiredTranscriptSubmission = Task { [weak self] in
                guard let self, !Task.isCancelled, !self.requestsStopped else { return }
                await self.send(text: turn.text)
                if !Task.isCancelled { self.expiredTranscriptSubmission = nil }
            }
        case .http(let status, let code, let retryAfter, _, let minimumVersion, _):
            // Refused before any processing: nothing happened, the text goes back to the composer.
            forget()
            phase = .idle
            if draft.isEmpty { draft = turn.text }
            notice = Self.refusal(status: status, code: code, retryAfter: retryAfter, minimumVersion: minimumVersion)
            if code == "CONVERSATION_NOT_FOUND" { newConversation() }
        case .unauthorized:
            forget()
            phase = .idle
            if draft.isEmpty { draft = turn.text }
            notice = "Cet iPhone n’est plus autorisé : voir Réglages."
        }
    }

    /// Local changes still in the queue are given 5 s to reach the server, then named in the request.
    private func waitForLocalChanges() async -> [String] {
        let deadline = Date().addingTimeInterval(5)
        var pendingIds = (try? await repository.pendingAggregateIds()) ?? []
        while !pendingIds.isEmpty && Date() < deadline && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            pendingIds = (try? await repository.pendingAggregateIds()) ?? []
        }
        return Array(pendingIds.prefix(500))
    }

    private func remember(_ turn: PendingTurn) {
        pending = turn
        if let data = try? JSONEncoder().encode(turn) { defaults.set(data, forKey: Keys.pending) }
        rebuild()
    }

    private func forget() {
        pending = nil
        defaults.removeObject(forKey: Keys.pending)
        rebuild()
    }

    // MARK: - Actions on a turn

    func choose(_ option: String) async {
        await send(text: option)
    }

    func confirm(_ controls: TurnControls, requestText: String?) async {
        guard let proposalId = controls.proposalId, let planHash = controls.planHash else { return }
        busy.insert(controls.turnId)
        defer { busy.remove(controls.turnId) }
        do {
            _ = try await api.confirmProposal(proposalId, planHash: planHash)
            successCount += 1
            AccessibilityNotification.Announcement("Proposition appliquée.").post()
        } catch APIError.http(_, let code, _, _, _, _) where code == "PROPOSAL_STALE" || code == "PROPOSAL_EXPIRED" {
            notice = code == "PROPOSAL_EXPIRED"
                ? "Proposition expirée. Redemandez pour obtenir un nouvel aperçu."
                : "La liste a changé depuis. Redemandez pour voir le nouvel aperçu."
            if let requestText, draft.isEmpty { draft = requestText }
        } catch {
            notice = Self.failureText(error)
        }
    }

    func reject(_ controls: TurnControls) async {
        guard let proposalId = controls.proposalId else { return }
        busy.insert(controls.turnId)
        defer { busy.remove(controls.turnId) }
        do {
            try await api.rejectProposal(proposalId)
        } catch {
            notice = Self.failureText(error)
        }
    }

    @discardableResult
    func undo(actionId: String) async -> Bool {
        busy.insert(actionId)
        defer { busy.remove(actionId) }
        do {
            _ = try await api.undoAction(actionId, requestId: UUID().uuidString.lowercased())
            AccessibilityNotification.Announcement("Action annulée.").post()
            return true
        } catch APIError.http(_, let code, _, _, _, let message) where code == "UNDO_CONFLICT" || code == "UNDO_EXPIRED" || code == "UNDO_NOT_AVAILABLE" {
            notice = code == "UNDO_EXPIRED" ? "Annulation impossible : plus de 24 h se sont écoulées."
                : code == "UNDO_CONFLICT" ? "Annulation impossible. \(message ?? "")"
                : "Cette action ne peut pas être annulée."
            return false
        } catch {
            notice = Self.failureText(error)
            return false
        }
    }

    /// "Corriger": the text returns to the composer; after an effect, sending undoes it first.
    func correct(_ entry: ThreadEntry) {
        let controls = turns[entry.message.turnId ?? ""]
        revising = (entry.message.id, controls?.canUndo == true ? controls?.undoActionId : nil)
        draft = entry.message.text
    }

    func cancelCorrection() {
        revising = nil
    }

    func deleteMessage(_ entry: ThreadEntry) async {
        do {
            try await api.deleteMessage(entry.message.id)
        } catch {
            notice = Self.failureText(error)
        }
    }

    func deleteConversation(_ id: String) async {
        do {
            try await api.deleteConversation(id)
            if id == conversationId { newConversation() }
        } catch APIError.http(404, _, _, _, _, _) {
            if id == conversationId { newConversation() }
        } catch {
            notice = Self.failureText(error)
        }
    }

    // MARK: - Thread

    private func rebuild() {
        var byId: [String: ThreadMessage] = [:]
        for message in messages { byId[message.id] = message }
        // Answers already returned by the server appear before their replication.
        for snapshot in snapshots.values where snapshot.conversationId == conversationId {
            for message in snapshot.messages where byId[message.id] == nil {
                byId[message.id] = ThreadMessage(
                    id: message.id, seq: message.seq, role: message.role, kind: message.kind, text: message.text,
                    originalTranscript: nil, turnId: snapshot.turnId, createdAt: nil
                )
            }
        }
        if let pending, pending.conversationId == conversationId, byId[pending.messageId] == nil {
            byId[pending.messageId] = ThreadMessage(
                id: pending.messageId, seq: Int.max, role: "user", kind: pending.transcriptionId == nil ? "text" : "voice",
                text: pending.text, originalTranscript: nil, turnId: pending.turnId, createdAt: nil
            )
        }
        let ordered = byId.values.sorted { $0.seq < $1.seq }
        var lastAssistantIndex: [String: Int] = [:]
        var userText: [String: String] = [:]
        for (index, message) in ordered.enumerated() {
            guard let turnId = message.turnId else { continue }
            if message.isUser { userText[turnId] = message.text } else { lastAssistantIndex[turnId] = index }
        }
        let latestAssistant = ordered.lastIndex { !$0.isUser }
        entries = ordered.enumerated().map { index, message in
            var entry = ThreadEntry(message: message)
            if let turnId = message.turnId, lastAssistantIndex[turnId] == index {
                entry.controls = turns[turnId] ?? snapshots[turnId].map(Self.controls(from:))
                entry.requestText = userText[turnId]
                if index == latestAssistant, message.kind == "clarification" {
                    entry.options = snapshots[turnId]?.clarification?.options ?? []
                }
            }
            return entry
        }
    }

    private static func controls(from snapshot: TurnSnapshot) -> TurnControls {
        TurnControls(
            turnId: snapshot.turnId,
            status: snapshot.status,
            errorCode: snapshot.error?.code,
            proposalId: snapshot.proposal?.proposalId,
            planHash: snapshot.proposal?.planHash,
            proposalState: snapshot.proposal?.state,
            proposalExpiresAt: Timestamp.parse(snapshot.proposal?.expiresAt),
            undoActionId: snapshot.undo?.actionId,
            undoState: snapshot.undo?.state,
            undoExpiresAt: Timestamp.parse(snapshot.undo?.expiresAt),
            taskIds: snapshot.results.filter { $0.aggregateType == "task" }.map(\.aggregateId)
        )
    }

    // MARK: - Texts

    private static let neverSent: Set<URLError.Code> = [
        .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
        .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed,
    ]

    private static func announcement(for snapshot: TurnSnapshot) -> String {
        switch snapshot.status {
        case "completed": snapshot.results.isEmpty ? "Réponse reçue." : "Action appliquée."
        case "awaiting_confirmation": "Proposition à confirmer."
        case "awaiting_clarification": "L’assistant demande une précision."
        case "cancelled": "Demande annulée."
        default: "La demande a échoué."
        }
    }

    private static func refusal(status: Int, code: String?, retryAfter: TimeInterval?, minimumVersion: String?) -> String {
        switch code {
        case "TOO_MANY_TURNS": return "Deux demandes sont déjà en cours. Attendez leur résultat."
        case "RATE_LIMITED":
            let minutes = max(1, Int(((retryAfter ?? 60) / 60).rounded(.up)))
            return "Trop de demandes cette heure-ci. Réessayez dans \(minutes) min."
        case "ASSISTANT_BUDGET_EXCEEDED": return "Limite mensuelle de l’assistant atteinte. Les tâches restent utilisables."
        case "ASSISTANT_UNAVAILABLE": return "L’assistant n’est pas configuré sur le serveur."
        case "CONVERSATION_NOT_FOUND": return "Cette conversation n’existe plus. Une nouvelle a été ouverte."
        case "REVISED_MESSAGE_UNKNOWN": return "Le message corrigé n’existe plus."
        case "INVALID_REFERENCE_INSTANT": return "L’heure de cet iPhone semble fausse. Vérifiez Réglages › Général › Date et heure."
        case "TRANSCRIPTION_UNKNOWN": return "La transcription n’est plus disponible."
        case "CLIENT_TOO_OLD": return "Mettez l’app à jour\(minimumVersion.map { " (minimum \($0))" } ?? "")."
        default: return "Demande refusée par le serveur (\(code ?? "HTTP \(status)")). Votre message est conservé."
        }
    }

    static func failureText(_ error: any Error) -> String {
        switch error as? APIError {
        case .transport: "Pas de réseau : réessayez quand la connexion revient."
        case .unauthorized: "Cet iPhone n’est plus autorisé : voir Réglages."
        case .http(let status, let code, _, _, _, _): "Action refusée (\(code ?? "HTTP \(status)"))."
        default: "Action impossible pour le moment."
        }
    }
}
