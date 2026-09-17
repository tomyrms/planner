import SwiftUI
import UIKit

/// Assistant (02_Design/04_IA_Chat_UX.md): messages, results with Annuler, proposals, questions, composer.
struct AssistantView: View {
    @Environment(AppServices.self) private var services
    @State private var showingHistory = false
    @FocusState private var composerFocused: Bool

    private var store: AssistantStore { services.assistant }

    var body: some View {
        NavigationStack {
            ConversationTimeline()
                .id(store.conversationId)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Composer(focused: $composerFocused)
                }
                .navigationTitle("Assistant")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Historique", systemImage: "clock.arrow.circlepath") { showingHistory = true }
                            .disabled(services.voice.phase != .idle)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Nouvelle conversation", systemImage: "square.and.pencil") { store.newConversation() }
                            .disabled(store.pending != nil || store.isBusy || (store.isEmptyConversation && store.draft.isEmpty) || services.voice.phase != .idle)
                    }
                }
                .sheet(isPresented: $showingHistory) {
                    ConversationHistoryView()
                }
                .sensoryFeedback(.success, trigger: store.successCount)
                .task { store.start() }
        }
    }
}

/// A conversation owns its scroll state. Geometry only reports whether the bottom is near;
/// appending a response never changes a reader's decision to stay higher in the history.
private struct ConversationTimeline: View {
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
                        EmptyAssistantHint()
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
                .padding(Spacing.lg)
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

private struct EmptyAssistantHint: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Écris ou dicte une demande.")
                .font(.headline)
            Text("« Demain 17 h, appeler le garage »")
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One message; the assistant's last message of a turn carries the turn's actions.
private struct MessageView: View {
    let entry: ThreadEntry
    @Environment(AppServices.self) private var services
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
            Text(message.text)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityLabel((message.kind == "voice" ? "Vous, vocal : " : "Vous : ") + message.text)
            if let original = message.originalTranscript {
                Text("Transcription d’origine : « \(original) »")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.md) { userMetadata }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .trailing, spacing: Spacing.xs) { userMetadata }
            }
        }
        .padding(.leading, dynamicTypeSize.isAccessibilitySize ? 0 : 32)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var userMetadata: some View {
        Text(message.kind == "voice" ? "Vous · Vocal" : "Vous")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        if message.kind == "voice", services.assistant.pending == nil {
            Button("Corriger", systemImage: "pencil") { services.assistant.correct(entry) }
                .font(.footnote)
                .frame(minHeight: TouchTarget.comfort)
        }
    }

    @ViewBuilder
    private var assistantBlock: some View {
        let isCard = message.kind == "action_result" || message.kind == "proposal"
        let receipt = message.kind == "action_result" ? ReceiptLayout(text: message.text) : nil
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(receipt?.summary ?? heading)
                .font(isCard ? .headline : .caption.weight(.medium))
                .foregroundStyle(isCard ? Color.primary : Color.secondary)
                .accessibilityAddTraits(.isHeader)
            if let receipt {
                ReceiptBody(layout: receipt)
            } else if message.kind == "error" {
                Label(message.text, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else {
                Text(message.text)
                    .textSelection(.enabled)
            }
            if !entry.options.isEmpty {
                OptionsView(options: entry.options)
            }
            if let controls = entry.controls {
                TurnActionsView(controls: controls, kind: message.kind, requestText: entry.requestText)
            }
        }
        .padding(isCard ? Spacing.md : 0)
        .background {
            if isCard {
                RoundedRectangle(cornerRadius: Radius.medium).fill(Color(.secondarySystemBackground))
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var heading: String {
        switch message.kind {
        case "action_result": "Résultat"
        case "proposal": entry.controls?.canConfirm == true ? "À confirmer" : "Proposition"
        case "clarification": "À préciser"
        default: "Assistant"
        }
    }
}

/// Presentation of the server's receipt text. Every line stays visible and in its original order;
/// grouping adds hierarchy without interpreting a task name as an action or claiming new effects.
private nonisolated struct ReceiptLayout {
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

private struct ReceiptBody: View {
    let layout: ReceiptLayout

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            ForEach(layout.blocks) { block in
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(block.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(block.isWarning ? Color.orange : Color.primary)
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

/// Native buttons keep their full labels; wide rows become a column before text is compressed.
private struct ChatActions<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let content: Content
    let alignment: Alignment

    init(alignment: Alignment = .trailing, @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.content = content()
    }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            column
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.md) { content }
                    .fixedSize(horizontal: true, vertical: false)
                column
            }
            .frame(maxWidth: .infinity, alignment: alignment)
        }
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) { content }
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
                Button(option) {
                    Task { await services.assistant.choose(option) }
                }
                .buttonStyle(.bordered)
                .frame(minHeight: TouchTarget.comfort)
                .disabled(services.assistant.isBusy || services.assistant.pending != nil)
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
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(taskIds.count == 1 ? "Ouvrir la tâche" : "Ouvrir les tâches")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
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
                HStack {
                    Spacer()
                    Button("Annuler") {
                        Task { await store.undo(actionId: actionId) }
                    }
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

    var body: some View {
        Group {
            if let task {
                Button {
                    editing = true
                } label: {
                    HStack {
                        Text(task.title)
                            .strikethrough(task.isCompleted)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(minHeight: TouchTarget.comfort)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Ouvrir « \(task.title) »")
                .sheet(isPresented: $editing) {
                    TaskEditorView(mode: .edit(task))
                }
            }
        }
        .task(id: taskId) {
            do {
                for try await rows in try services.tasks.observeTask(id: taskId) {
                    task = rows.first
                }
            } catch {}
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
                status("Envoi…")
            case .waiting:
                ChatActions(alignment: .leading) {
                    status("Compréhension…")
                    Button("Annuler") { Task { await store.cancelTurn() } }
                        .font(.footnote)
                        .frame(minHeight: TouchTarget.comfort)
                }
            case .unknown:
                Text("Résultat inconnu.")
                Button("Vérifier le résultat") { Task { await store.verify() } }
                    .buttonStyle(.bordered)
                    .frame(minHeight: TouchTarget.comfort)
            case .offline:
                Text("L’assistant a besoin du réseau. Ton message est gardé.")
                ChatActions(alignment: .leading) {
                    Button("Envoyer") { Task { await store.resend() } }
                        .buttonStyle(.bordered)
                        .frame(minHeight: TouchTarget.comfort)
                    Button("Modifier le message") { store.discardPending() }
                        .frame(minHeight: TouchTarget.comfort)
                }
            case .notReceived:
                Text("Le serveur n’a pas reçu cette demande.")
                ChatActions(alignment: .leading) {
                    Button("Envoyer") { Task { await store.resend() } }
                        .buttonStyle(.bordered)
                        .frame(minHeight: TouchTarget.comfort)
                    Button("Modifier le message") { store.discardPending() }
                        .frame(minHeight: TouchTarget.comfort)
                }
            case .refused:
                Text("Le message n’a pas été accepté. Il est conservé.")
                ChatActions(alignment: .leading) {
                    Button("Réessayer") { Task { await store.resend() } }
                        .buttonStyle(.bordered)
                        .frame(minHeight: TouchTarget.comfort)
                    Button("Modifier le message") { store.discardPending() }
                        .frame(minHeight: TouchTarget.comfort)
                }
            }
            if let notice = store.notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func status(_ text: String) -> some View {
        HStack(spacing: Spacing.sm) {
            ProgressView()
            Text(text)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Text field, microphone and send; the draft survives failures and closing the app.
private struct Composer: View {
    @FocusState.Binding var focused: Bool
    @Environment(AppServices.self) private var services
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var store: AssistantStore { services.assistant }

    var body: some View {
        VStack(spacing: Spacing.xs) {
            if store.revising != nil {
                ChatActions(alignment: .leading) {
                    Label(store.revising?.undoActionId == nil ? "Correction du message" : "Correction : l’action précédente sera annulée",
                          systemImage: "pencil")
                        .font(.footnote)
                    Button("Annuler la correction") { store.cancelCorrection() }
                        .font(.footnote)
                        .frame(minHeight: TouchTarget.comfort)
                }
            }
            VoiceDraftBar()
            if let notice = services.voice.notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if services.voice.phase == .recording {
                VoiceRecorderBar()
            } else if services.voice.phase == .finishing {
                HStack(spacing: Spacing.sm) {
                    ProgressView()
                    Text("Finalisation du vocal…")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, minHeight: TouchTarget.comfort, alignment: .leading)
                .accessibilityElement(children: .combine)
            } else if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .trailing, spacing: Spacing.xs) {
                    messageField
                    HStack(spacing: Spacing.sm) { captureAndSend }
                }
            } else {
                HStack(alignment: .bottom, spacing: Spacing.sm) {
                    messageField
                    captureAndSend
                }
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .background(.bar)
    }

    private var messageField: some View {
        @Bindable var store = services.assistant
        return TextField("Message…", text: $store.draft, axis: .vertical)
            .lineLimit(1...5)
            .focused($focused)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .frame(minHeight: TouchTarget.comfort)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: Radius.medium))
            .accessibilityLabel("Message à l’assistant")
    }

    @ViewBuilder
    private var captureAndSend: some View {
        if services.voice.draft == nil { VoiceButton() }
        Button {
            Task { await store.send() }
        } label: {
            Image(systemName: "arrow.up.circle.fill")
                .font(.title2)
                .frame(minWidth: TouchTarget.comfort, minHeight: TouchTarget.comfort)
        }
        .disabled(!store.canSend || services.voice.isWorking)
        .accessibilityLabel("Envoyer")
    }
}

/// Conversations kept until deleted; deleting one never deletes its tasks.
struct ConversationHistoryView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var conversations: [ConversationSummary] = []
    @State private var pendingDeletion: ConversationSummary?

    var body: some View {
        NavigationStack {
            List {
                ForEach(conversations) { conversation in
                    Button {
                        services.assistant.open(conversation: conversation.id)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text(conversation.title)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            if let updatedAt = conversation.updatedAt {
                                Text(updatedAt.formatted(.relative(presentation: .named)))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions {
                        Button("Supprimer", systemImage: "trash", role: .destructive) { pendingDeletion = conversation }
                    }
                    .contextMenu {
                        Button("Supprimer", systemImage: "trash", role: .destructive) { pendingDeletion = conversation }
                    }
                }
            }
            .overlay {
                if conversations.isEmpty {
                    ContentUnavailableView("Aucune conversation.", systemImage: "text.bubble")
                }
            }
            .navigationTitle("Historique")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
            .confirmationDialog("Supprimer cette conversation ?", isPresented: deletionBinding, titleVisibility: .visible, presenting: pendingDeletion) { conversation in
                Button("Supprimer", role: .destructive) {
                    Task { await services.assistant.deleteConversation(conversation.id) }
                }
            } message: { _ in
                Text("Les messages sont supprimés. Les tâches créées restent.")
            }
            .task {
                do {
                    for try await rows in try services.assistantHistory.observeConversations() {
                        conversations = rows
                    }
                } catch {}
            }
        }
    }

    private var deletionBinding: Binding<Bool> {
        Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
    }
}
