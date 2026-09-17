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
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Spacing.md) {
                        if store.isEmptyConversation {
                            EmptyAssistantHint()
                        }
                        ForEach(store.entries) { entry in
                            MessageView(entry: entry)
                                .id(entry.id)
                        }
                        TurnStateView()
                            .id("state")
                    }
                    .padding(Spacing.lg)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: store.entries.count) {
                    withAnimation(.easeOut(duration: 0.22)) { proxy.scrollTo("state", anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo("state", anchor: .bottom) }
            }
            .safeAreaInset(edge: .bottom) {
                Composer(focused: $composerFocused)
            }
            .navigationTitle("Assistant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Historique", systemImage: "clock.arrow.circlepath") { showingHistory = true }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Nouvelle conversation", systemImage: "square.and.pencil") { store.newConversation() }
                        .disabled(store.pending != nil || store.isEmptyConversation)
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

private struct EmptyAssistantHint: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Écris ou dicte ce que tu veux ajouter, déplacer ou retrouver.")
            Text("« Demain 17 h, appeler le garage »")
                .foregroundStyle(.secondary)
            Text("« Qu’est-ce qu’il me reste aujourd’hui ? »")
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
    @State private var confirmingDelete = false

    private var message: ThreadMessage { entry.message }

    var body: some View {
        VStack(alignment: message.isUser ? .trailing : .leading, spacing: Spacing.sm) {
            if message.isUser {
                userBubble
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

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: Spacing.xs) {
            if message.kind == "voice" {
                Label("Vocal", systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(message.text)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: Radius.medium))
                .textSelection(.enabled)
            if let original = message.originalTranscript {
                Text("Transcription d’origine : « \(original) »")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel((message.kind == "voice" ? "Vous, vocal : " : "Vous : ") + message.text)
    }

    @ViewBuilder
    private var assistantBlock: some View {
        let isCard = message.kind == "action_result" || message.kind == "proposal"
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if message.kind == "error" {
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

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if kind == "action_result" || controls.proposalState == "confirmed" {
                ForEach(controls.taskIds.prefix(10), id: \.self) { taskId in
                    TaskLink(taskId: taskId)
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
            HStack {
                Spacer()
                Button("Annuler", role: .cancel) {
                    Task { await store.reject(controls) }
                }
                Button("Confirmer") {
                    Task { await store.confirm(controls, requestText: requestText) }
                }
                .buttonStyle(.borderedProminent)
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
        HStack {
            Text(reason)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            if let requestText {
                Button("Redemander") { store.draft = requestText }
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
                            .lineLimit(2)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    }
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
                HStack {
                    status("Compréhension…")
                    Spacer()
                    Button("Annuler") { Task { await store.cancelTurn() } }
                        .font(.footnote)
                }
            case .unknown:
                Text("Résultat inconnu.")
                Button("Vérifier le résultat") { Task { await store.verify() } }
                    .buttonStyle(.bordered)
            case .offline:
                Text("L’assistant a besoin du réseau. Ton message est gardé.")
                HStack {
                    Button("Envoyer") { Task { await store.resend() } }
                        .buttonStyle(.bordered)
                    Button("Modifier le message") { store.discardPending() }
                }
            case .notReceived:
                Text("Le serveur n’a pas reçu cette demande.")
                HStack {
                    Button("Envoyer") { Task { await store.resend() } }
                        .buttonStyle(.bordered)
                    Button("Modifier le message") { store.discardPending() }
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

    private var store: AssistantStore { services.assistant }

    var body: some View {
        @Bindable var store = services.assistant
        VStack(spacing: Spacing.xs) {
            if store.revising != nil {
                HStack {
                    Label(store.revising?.undoActionId == nil ? "Correction du message" : "Correction : l’action précédente sera annulée",
                          systemImage: "pencil")
                        .font(.footnote)
                    Spacer()
                    Button("Annuler la correction") { store.cancelCorrection() }
                        .font(.footnote)
                }
            }
            HStack(alignment: .bottom, spacing: Spacing.sm) {
                TextField("Message…", text: $store.draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($focused)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: Radius.medium))
                VoiceButton()
                Button {
                    Task { await store.send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                        .frame(minWidth: TouchTarget.comfort, minHeight: TouchTarget.comfort)
                }
                .disabled(!store.canSend)
                .accessibilityLabel("Envoyer")
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .background(.bar)
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
