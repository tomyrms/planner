import SwiftUI
import UIKit

/// Assistant (02_Design/04_IA_Chat_UX.md): messages, results with Annuler, proposals, questions, composer.
struct AssistantView: View {
    var recordingHandledByNavigation = false
    @Environment(AppServices.self) private var services
    @State private var showingHistory = false
    @FocusState private var composerFocused: Bool

    private var store: AssistantStore { services.assistant }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ConversationTimeline(onUseExample: {
                    guard store.draft.isEmpty, store.revising == nil, store.pending == nil, !store.isBusy else { composerFocused = true; return }
                    store.draft = EmptyAssistantHint.example
                    composerFocused = true
                })
                    .id(store.conversationId)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        Composer(focused: $composerFocused,
                                 accessoryHeight: max(76, min(200, geometry.size.height * 0.38)),
                                 recordingHandledByNavigation: recordingHandledByNavigation)
                    }
            }
                .background(Color(uiColor: .systemBackground))
                .navigationTitle("Assistant")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Conversations", systemImage: "clock.arrow.circlepath") { showingHistory = true }
                            .disabled(services.voice.phase != .idle || services.voice.isPreparingRecording)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Nouvelle conversation", systemImage: "square.and.pencil") { store.newConversation() }
                            .disabled(store.pending != nil || store.isBusy || (store.isEmptyConversation && store.draft.isEmpty) || services.voice.phase != .idle || services.voice.isPreparingRecording)
                    }
                }
                .sheet(isPresented: $showingHistory) {
                    ConversationHistoryView()
                }
                .sensoryFeedback(.success, trigger: store.successCount)
                .onChange(of: store.phase) { _, phase in
                    let announcement: String? = switch phase {
                    case .idle: nil
                    case .preparing: "Envoi du message"
                    case .waiting: "Compréhension de la demande"
                    case .unknown: "Résultat à vérifier"
                    case .offline: "Hors ligne. Le message est conservé."
                    case .notReceived: "Demande non reçue. Le message est conservé."
                    case .refused: "Message non accepté. Le message est conservé."
                    }
                    if let announcement { UIAccessibility.post(notification: .announcement, argument: announcement) }
                }
                .task { store.start() }
        }
    }
}

/// A conversation owns its scroll state. Geometry only reports whether the bottom is near;
/// appending a response never changes a reader's decision to stay higher in the history.
private struct ConversationTimeline: View {
    let onUseExample: () -> Void
    @Environment(AppServices.self) private var services
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var followsLatest = true
    @State private var userScrolling = false

    private static let bottomId = "assistant-thread-bottom"
    private var store: AssistantStore { services.assistant }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.xl) {
                    if store.isEmptyConversation {
                        EmptyAssistantHint(onUseExample: onUseExample)
                    }
                    ForEach(store.entries) { entry in
                        MessageView(entry: entry)
                            .id(entry.id)
                    }
                    TurnStateView()
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomId)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.top, Spacing.xl)
                .padding(.bottom, Spacing.md)
            }
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.visibleRect.maxY <= 60
            } action: { _, nearBottom in
                // Content growth can hide the bottom while idle. Only a user's scroll disables following.
                if userScrolling || nearBottom { followsLatest = nearBottom }
            }
            .onScrollPhaseChange { _, phase, context in
                switch phase {
                case .tracking, .interacting, .decelerating:
                    userScrolling = true
                    followsLatest = context.geometry.contentSize.height - context.geometry.visibleRect.maxY <= 60
                case .idle:
                    if userScrolling {
                        followsLatest = context.geometry.contentSize.height - context.geometry.visibleRect.maxY <= 60
                    }
                    userScrolling = false
                case .animating:
                    userScrolling = false
                }
            }
            .onChange(of: store.entries.map(\.id)) {
                if followsLatest && !UIAccessibility.isVoiceOverRunning { scrollToLatest(proxy) }
            }
            .onChange(of: store.pending?.messageId) { _, messageId in
                guard messageId != nil else { return }
                followsLatest = true
                scrollToLatest(proxy)
            }
            .onChange(of: store.phase) { _, phase in
                // The user's own new request is an explicit reason to return to the end.
                if phase == .preparing { followsLatest = true }
                if followsLatest && (phase == .preparing || !UIAccessibility.isVoiceOverRunning) { scrollToLatest(proxy) }
            }
            .onChange(of: store.notice) {
                if followsLatest && !UIAccessibility.isVoiceOverRunning { scrollToLatest(proxy) }
            }
            .onAppear { if followsLatest { scrollToLatest(proxy, animated: false) } }
        }
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated && !reduceMotion {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
        } else {
            proxy.scrollTo(Self.bottomId, anchor: .bottom)
        }
    }
}

/// One message; the assistant's last message of a turn carries the turn's actions.
private struct MessageView: View {
    let entry: ThreadEntry
    @Environment(AppServices.self) private var services
    @State private var confirmingDelete = false

    private var message: ThreadMessage { entry.message }

    var body: some View {
        VStack(alignment: message.isUser ? .trailing : .leading, spacing: Spacing.sm) {
            if message.isUser {
                userMessage
            } else {
                assistantBlock
            }
        }
        .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
        .contextMenu {
            Button("Copier", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
            if message.isUser, services.assistant.pending == nil {
                Button("Corriger", systemImage: "pencil") { services.assistant.correct(entry) }
            }
            Button("Supprimer le message", systemImage: "trash", role: .destructive) { confirmingDelete = true }
        }
        .confirmationDialog("Supprimer ce message ?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) {
                Task { await services.assistant.deleteMessage(entry) }
            }
        } message: {
            Text("Les tâches créées ou modifiées restent inchangées.")
        }
    }

    private var userMessage: some View {
        VStack(alignment: .trailing, spacing: Spacing.xs) {
            ChatUserBubble(text: message.text, isVoice: message.kind == "voice")
            if let original = message.originalTranscript {
                DisclosureGroup("Transcription d’origine") {
                    Text(original)
                        .font(.subheadline)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Spacing.sm)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.md) { userMetadata }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .trailing, spacing: Spacing.xs) { userMetadata }
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var userMetadata: some View {
        if message.kind == "voice" {
            Label("Vocal", systemImage: "waveform")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            if services.assistant.pending == nil {
                Button("Corriger", systemImage: "pencil") { services.assistant.correct(entry) }
                    .font(.footnote)
                    .frame(minHeight: TouchTarget.comfort)
            }
        }
    }

    @ViewBuilder
    private var assistantBlock: some View {
        let receipt = message.kind == "action_result" ? ReceiptLayout(text: message.text) : nil
        ChatReplyGroup(style: replyStyle, heading: receipt?.summary ?? heading) {
            if let receipt {
                ReceiptBody(layout: receipt)
            } else if message.kind == "text" {
                ChatAssistantText(text: message.text)
            } else {
                Text(message.text)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if !entry.options.isEmpty {
                OptionsView(options: entry.options)
            }
            if let controls = entry.controls {
                TurnActionsView(controls: controls, kind: message.kind, requestText: entry.requestText)
            }
        }
    }

    private var heading: String? {
        switch message.kind {
        case "action_result": "Résultat"
        case "proposal": entry.controls?.canConfirm == true ? "À confirmer" : "Proposition"
        case "clarification": "À préciser"
        case "error": "Demande non aboutie"
        default: nil
        }
    }

    private var replyStyle: ChatReplyStyle {
        switch message.kind {
        case "action_result": .result
        case "proposal": .proposal
        case "clarification": .question
        case "error": .error
        default: .text
        }
    }
}

/// Presentation of the server's receipt text. Every line stays visible and in its original order;
/// grouping adds hierarchy without interpreting a task name as an action or claiming new effects.
nonisolated struct ReceiptLayout {
    nonisolated struct Block: Identifiable {
        let id: Int
        let title: String
        let details: String
        let isWarning: Bool
    }

    let summary: String?
    let blocks: [Block]

    init(text: String) {
        var lines = text.components(separatedBy: "\n")
        if let first = lines.first,
           first.range(of: #"^[1-9][0-9]* (tâches ajoutées|tâches mises à la corbeille|changements)$"#, options: .regularExpression) != nil {
            summary = lines.removeFirst()
        } else {
            summary = nil
        }
        let stepPrefixes = [
            "Ajouté : ", "Modifié : ", "Déplacé : ", "Terminé : ", "Rouvert : ",
            "Mis à la corbeille : ", "Restauré : ", "Liste créée : ", "Série modifiée : ",
            "Série terminée : ", "Ignoré : ", "Non fait : "
        ]
        var groups: [[String]] = []
        for line in lines {
            if groups.isEmpty || stepPrefixes.contains(where: { line.hasPrefix($0) }) {
                groups.append([line])
            } else {
                groups[groups.count - 1].append(line)
            }
        }
        blocks = groups.enumerated().map { index, lines in
            Block(id: index, title: lines[0], details: lines.dropFirst().joined(separator: "\n"), isWarning: lines[0].hasPrefix("Non fait : "))
        }
    }
}

struct ReceiptBody: View {
    let layout: ReceiptLayout

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            ForEach(layout.blocks) { block in
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                        if block.isWarning {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                                .accessibilityHidden(true)
                        }
                        Text(block.title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                    }
                    if !block.details.isEmpty {
                        Text(block.details)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineSpacing(3)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Touchable answers to a question: each is sent as a new message.
private struct OptionsView: View {
    let options: [String]
    @Environment(AppServices.self) private var services

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(options, id: \.self) { option in
                Button {
                    Task { await services.assistant.choose(option) }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                        Text(option).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: Spacing.sm)
                        Image(systemName: "arrow.turn.down.left").font(.footnote).accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, minHeight: TouchTarget.comfort, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(services.assistant.isBusy || services.assistant.pending != nil)
                if option != options.last { Divider() }
            }
        }
    }
}

/// Confirm / cancel a proposal, undo a result, open the tasks it touched.
private struct TurnActionsView: View {
    let controls: TurnControls
    let kind: String
    let requestText: String?
    @Environment(AppServices.self) private var services

    private var store: AssistantStore { services.assistant }
    private var busy: Bool { store.busy.contains(controls.turnId) || store.busy.contains(controls.undoActionId ?? "") }
    private var taskIds: [String] {
        var seen: Set<String> = []
        return controls.taskIds.filter { seen.insert($0).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if kind == "action_result" || controls.proposalState == "confirmed" {
                if !taskIds.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Divider()
                        ForEach(taskIds, id: \.self) { taskId in
                            TaskLink(taskId: taskId)
                        }
                    }
                    .padding(.top, Spacing.xs)
                }
            }
            if kind == "proposal" {
                proposalButtons
            }
            if controls.canUndo, let actionId = controls.undoActionId {
                ChatActions(alignment: .leading) {
                    Button("Annuler l’action", systemImage: "arrow.uturn.backward") {
                        Task { await store.undo(actionId: actionId) }
                    }
                    .font(.subheadline)
                    .disabled(busy)
                    .frame(minHeight: TouchTarget.comfort)
                }
            } else if let reason = undoReason {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var proposalButtons: some View {
        switch controls.proposalState ?? "" {
        case "pending" where controls.canConfirm:
            ChatActions {
                Button("Annuler", role: .cancel) {
                    Task { await store.reject(controls) }
                }
                .frame(minHeight: TouchTarget.comfort)
                Button("Confirmer") {
                    Task { await store.confirm(controls, requestText: requestText) }
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .frame(minHeight: TouchTarget.comfort)
            }
            .disabled(busy)
            if let expiresAt = controls.proposalExpiresAt {
                Text("Expire \(expiresAt.formatted(.relative(presentation: .named)))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case "pending", "expired":
            redo("Proposition expirée.")
        case "superseded":
            Text("Remplacée par une demande plus récente.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case "rejected":
            Text("Proposition annulée. Rien n’a été modifié.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case "confirmed":
            Label("Confirmée", systemImage: "checkmark.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    private func redo(_ reason: String) -> some View {
        ChatActions {
            Text(reason)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let requestText {
                Button("Redemander") { store.draft = requestText }
                    .frame(minHeight: TouchTarget.comfort)
                    .disabled(!store.draft.isEmpty || store.revising != nil || store.pending != nil || store.isBusy)
            }
        }
    }

    private var undoReason: String? {
        switch controls.undoState ?? "" {
        case "undone": "Annulée."
        case "conflict": "Annulation impossible : modifiée depuis."
        case "expired": "Annulation expirée (24 h)."
        default: nil
        }
    }
}

/// A task touched by the assistant; opens its editor.
private struct TaskLink: View {
    let taskId: String
    @Environment(AppServices.self) private var services
    @State private var task: TaskItem?
    @State private var editing = false
    @State private var loaded = false
    @State private var readFailed = false
    @State private var retry = 0
    @State private var subtasksExpanded = false

    var body: some View {
        Group {
            if let task {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                        Button { editing = true } label: {
                            HStack(spacing: Spacing.sm) {
                                Image(systemName: "checklist")
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                                Text(task.title)
                                    .font(.subheadline)
                                    .strikethrough(task.isCompleted)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                if task.subtasks.isEmpty {
                                    Image(systemName: "chevron.right")
                                        .font(.footnote)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .frame(minHeight: TouchTarget.comfort)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Ouvrir « \(task.title) »")
                        if !task.subtasks.isEmpty {
                            TaskSubtaskDisclosureButton(taskTitle: task.title, subtasks: task.subtasks, isExpanded: $subtasksExpanded)
                        }
                    }
                    TaskTagLinks(taskId: task.id).padding(.leading, Spacing.xl)
                    if subtasksExpanded && !task.subtasks.isEmpty {
                        TaskSubtaskList(subtasks: task.subtasks).padding(.leading, Spacing.xl)
                    }
                }
                .onChange(of: task.subtasks.isEmpty) { _, empty in if empty { subtasksExpanded = false } }
                .sheet(isPresented: $editing) {
                    TaskEditorView(mode: .edit(task))
                }
            } else if readFailed {
                Button("Recharger la tâche", systemImage: "arrow.clockwise") { retry += 1 }
                    .font(.subheadline)
                    .frame(minHeight: TouchTarget.comfort)
            } else if loaded {
                ChatNotice(text: "Cette tâche n’est pas disponible sur cet iPhone.")
            } else {
                ChatProgressLabel(text: "Chargement de la tâche…")
            }
        }
        .task(id: taskId + "-\(retry)") {
            readFailed = false
            do {
                for try await rows in try services.tasks.observeTask(id: taskId) {
                    guard !Task.isCancelled else { return }
                    task = rows.first
                    loaded = true
                }
            } catch { if !Task.isCancelled { readFailed = true } }
        }
    }
}

/// State of the request in flight or left without an answer.
private struct TurnStateView: View {
    @Environment(AppServices.self) private var services

    private var store: AssistantStore { services.assistant }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            switch store.phase {
            case .idle:
                EmptyView()
            case .preparing:
                ChatProgressLabel(text: "Envoi…")
            case .waiting:
                ChatActions(alignment: .leading) {
                    ChatProgressLabel(text: "Compréhension…")
                    Button("Annuler") { Task { await store.cancelTurn() } }
                        .font(.footnote)
                        .frame(minHeight: TouchTarget.comfort)
                }
            case .unknown:
                ChatNotice(text: "Résultat inconnu. Vérifie la réponse avant de continuer.", symbol: "questionmark.circle")
                Button("Vérifier le résultat") { Task { await store.verify() } }
                    .frame(minHeight: TouchTarget.comfort)
            case .offline:
                ChatNotice(text: "L’assistant a besoin du réseau. Ton message est gardé.", symbol: "wifi.slash")
                ChatActions(alignment: .leading) {
                    Button("Envoyer") { Task { await store.resend() } }
                        .frame(minHeight: TouchTarget.comfort)
                    Button("Modifier le message") { store.discardPending() }
                        .frame(minHeight: TouchTarget.comfort)
                }
            case .notReceived:
                ChatNotice(text: "Le serveur n’a pas reçu cette demande.", symbol: "arrow.up.circle")
                ChatActions(alignment: .leading) {
                    Button("Envoyer") { Task { await store.resend() } }
                        .frame(minHeight: TouchTarget.comfort)
                    Button("Modifier le message") { store.discardPending() }
                        .frame(minHeight: TouchTarget.comfort)
                }
            case .refused:
                ChatNotice(text: "Le message n’a pas été accepté. Il est conservé.", symbol: "exclamationmark.circle")
                ChatActions(alignment: .leading) {
                    Button("Réessayer") { Task { await store.resend() } }
                        .frame(minHeight: TouchTarget.comfort)
                    Button("Modifier le message") { store.discardPending() }
                        .frame(minHeight: TouchTarget.comfort)
                }
            }
            if let notice = store.notice {
                ChatNotice(text: notice)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

/// Text field, microphone and send; the draft survives failures and closing the app.
private struct Composer: View {
    @FocusState.Binding var focused: Bool
    let accessoryHeight: CGFloat
    let recordingHandledByNavigation: Bool
    @Environment(AppServices.self) private var services
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var store: AssistantStore { services.assistant }

    var body: some View {
        ChatComposerSurface {
            VStack(spacing: Spacing.xs) {
                if hasAccessories {
                    ComposerAccessories(maximumHeight: accessoryHeight) { accessories }
                        .padding(.horizontal, Spacing.sm)
                        .padding(.top, Spacing.sm)
                    Divider().padding(.horizontal, Spacing.sm)
                }
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .trailing, spacing: 0) {
                        messageField
                        HStack(spacing: Spacing.xs) { captureAndSend }
                    }
                } else {
                    HStack(alignment: .bottom, spacing: Spacing.xs) {
                        messageField
                        captureAndSend
                    }
                }
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .onChange(of: services.voice.phase) { _, phase in
            let announcement: String? = switch phase {
            case .idle: nil
            case .recording: "Enregistrement en cours"
            case .finishing: "Finalisation du vocal"
            case .checking: "Vérification du vocal"
            case .uploading: "Envoi du vocal"
            case .transcribing: "Transcription en cours"
            case .delivering: "Envoi du texte transcrit"
            }
            if let announcement { UIAccessibility.post(notification: .announcement, argument: announcement) }
        }
    }

    private var hasAccessories: Bool {
        store.revising != nil || services.voice.draft != nil || services.voice.notice != nil ||
            (services.voice.phase == .recording && !recordingHandledByNavigation) || services.voice.phase == .finishing || services.voice.permissionDenied
    }

    private var accessories: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if store.revising != nil {
                ChatActions(alignment: .leading) {
                    Label(store.revising?.undoActionId == nil ? "Correction du message" : "Correction : l’action précédente sera annulée",
                          systemImage: "pencil")
                        .font(.footnote)
                    Button { store.cancelCorrection() } label: {
                        Image(systemName: "xmark")
                            .font(.footnote.weight(.semibold))
                            .frame(width: TouchTarget.comfort, height: TouchTarget.comfort)
                    }
                    .accessibilityLabel("Annuler la correction")
                }
            }
            VoiceDraftBar()
            if let notice = services.voice.notice {
                ChatNotice(text: notice)
            }
            if services.voice.phase == .recording && !recordingHandledByNavigation {
                VoiceRecorderBar()
            } else if services.voice.phase == .finishing {
                ChatProgressLabel(text: "Finalisation du vocal…")
                .frame(maxWidth: .infinity, minHeight: TouchTarget.comfort, alignment: .leading)
            }
            if services.voice.permissionDenied {
                ChatNotice(text: "Le micro n’est pas autorisé. Tu peux toujours écrire.", symbol: "mic.slash")
                ChatActions(alignment: .leading) {
                    Button("Ouvrir Réglages") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            services.voice.permissionDenied = false
                            UIApplication.shared.open(url)
                        }
                    }
                    .frame(minHeight: TouchTarget.comfort)
                    Button("Plus tard") { services.voice.permissionDenied = false }
                        .frame(minHeight: TouchTarget.comfort)
                }
            }
        }
    }

    private var messageField: some View {
        @Bindable var store = services.assistant
        return TextField("Écris une demande…", text: $store.draft, axis: .vertical)
            .lineLimit(1...(dynamicTypeSize.isAccessibilitySize ? 2 : 5))
            .focused($focused)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .frame(minHeight: TouchTarget.comfort)
            .accessibilityLabel("Message à l’assistant")
    }

    @ViewBuilder
    private var captureAndSend: some View {
        if services.voice.draft == nil, services.voice.phase != .recording, services.voice.phase != .finishing { VoiceButton() }
        ChatSendButton(enabled: store.canSend && services.voice.phase == .idle && !services.voice.isPreparingRecording) {
            Task { await store.send() }
        }
    }
}

/// A long recovery explanation or large-text voice draft can scroll without pushing the field off
/// the keyboard. The maximum comes from the actual available area, not a guessed tab/keyboard height.
private struct ComposerAccessories<Content: View>: View {
    let maximumHeight: CGFloat
    let content: Content
    @State private var contentHeight: CGFloat = 1

    init(maximumHeight: CGFloat, @ViewBuilder content: () -> Content) {
        self.maximumHeight = maximumHeight
        self.content = content()
    }

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(contentHeight, maximumHeight))
    }
}

/// Conversations kept until deleted; deleting one never deletes its tasks.
struct ConversationHistoryView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var conversations: [ConversationSummary] = []
    @State private var pendingDeletion: ConversationSummary?
    @State private var loading = true
    @State private var readFailed = false
    @State private var retry = 0

    var body: some View {
        NavigationStack {
            List {
                if readFailed, !conversations.isEmpty { historyReadError }
                if services.assistant.pending != nil || services.assistant.isBusy {
                    ChatNotice(text: "Une demande attend encore son résultat dans la conversation actuelle.")
                }
                ForEach(conversations) { conversation in
                    Button {
                        services.assistant.open(conversation: conversation.id)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: Spacing.sm) {
                            Text(conversation.title)
                                .foregroundStyle(.primary)
                                .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                            if let updatedAt = conversation.updatedAt {
                                Text(updatedAt.formatted(.relative(presentation: .named)))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, Spacing.xs)
                    }
                    .disabled(services.assistant.pending != nil || services.assistant.isBusy)
                    .swipeActions {
                        Button("Supprimer", systemImage: "trash", role: .destructive) { pendingDeletion = conversation }
                    }
                    .contextMenu {
                        Button("Supprimer", systemImage: "trash", role: .destructive) { pendingDeletion = conversation }
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if conversations.isEmpty {
                    if loading {
                        ChatProgressLabel(text: "Chargement des conversations…")
                    } else if readFailed {
                        ContentUnavailableView {
                            Label("Historique indisponible", systemImage: "exclamationmark.bubble")
                        } description: {
                            Text("Les conversations n’ont pas pu être lues sur cet iPhone.")
                        } actions: {
                            Button("Réessayer") { retry += 1 }
                                .frame(minHeight: TouchTarget.comfort)
                        }
                    } else if services.sync.hasSynced != true {
                        VStack { SyncNotice() }.padding(Spacing.lg)
                    } else {
                        ContentUnavailableView("Aucune conversation", systemImage: "text.bubble", description: Text("Tes échanges avec l’assistant apparaîtront ici."))
                    }
                }
            }
            .navigationTitle("Conversations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
            .confirmationDialog("Supprimer cette conversation ?", isPresented: deletionBinding, titleVisibility: .visible, presenting: pendingDeletion) { conversation in
                Button("Supprimer", role: .destructive) {
                    Task { await services.assistant.deleteConversation(conversation.id) }
                }
            } message: { _ in
                Text("Les messages sont supprimés. Les tâches créées restent.")
            }
            .task(id: retry) {
                loading = conversations.isEmpty
                readFailed = false
                do {
                    for try await rows in try services.assistantHistory.observeConversations() {
                        guard !Task.isCancelled else { return }
                        conversations = rows
                        loading = false
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    loading = false
                    readFailed = true
                }
            }
        }
    }

    private var deletionBinding: Binding<Bool> {
        Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
    }

    private var historyReadError: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ChatNotice(text: "L’historique n’a pas pu être actualisé.", symbol: "exclamationmark.circle")
            Button("Réessayer") { retry += 1 }
                .frame(minHeight: TouchTarget.comfort)
        }
    }
}
