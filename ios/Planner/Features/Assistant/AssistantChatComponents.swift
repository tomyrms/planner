import Foundation
import SwiftUI

/// Natural language replies may include emphasis. Keep line breaks; receipts and user-entered
/// task names retain their separate, literal presentation paths.
struct ChatAssistantText: View {
    let text: String

    var body: some View {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// Presentation only: these components can be previewed without a database, pairing or network.
struct ChatUserBubble: View {
    let text: String
    var isVoice = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Text(text)
            .font(.body)
            .lineSpacing(3)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
            .padding(.leading, typeSize.isAccessibilitySize ? 0 : 40)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityLabel((isVoice ? "Vous, vocal : " : "Vous : ") + text)
    }
}

enum ChatReplyStyle: Equatable { case text, result, proposal, question, error }

/// Only a proposal gets a filled surface: its exact preview and decision belong together.
/// Results use a quiet leading rule; ordinary answers stay directly on the conversation background.
struct ChatReplyGroup<Content: View>: View {
    let style: ChatReplyStyle
    let heading: String?
    let content: Content

    init(style: ChatReplyStyle, heading: String? = nil, @ViewBuilder content: () -> Content) {
        self.style = style
        self.heading = heading
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            if let heading {
                Label(heading, systemImage: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(style == .error ? Color.primary : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(style == .proposal ? Spacing.lg : 0)
        .padding(.leading, style == .result ? Spacing.md : 0)
        .background {
            if style == .proposal {
                RoundedRectangle(cornerRadius: 20).fill(Color(uiColor: .secondarySystemBackground))
            }
        }
        .overlay(alignment: .leading) {
            if style == .result {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color(uiColor: .separator))
                    .frame(width: 2)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var symbol: String {
        switch style {
        case .text: "text.bubble"
        case .result: "checklist"
        case .proposal: "checkmark.circle"
        case .question: "questionmark.circle"
        case .error: "exclamationmark.triangle"
        }
    }
}

struct ChatComposerSurface<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .padding(6)
            .background {
                if reduceTransparency {
                    RoundedRectangle(cornerRadius: 26).fill(Color(uiColor: .secondarySystemBackground))
                } else {
                    RoundedRectangle(cornerRadius: 26).fill(.regularMaterial)
                }
            }
            .overlay {
                if contrast == .increased {
                    RoundedRectangle(cornerRadius: 26)
                        .strokeBorder(Color.primary.opacity(0.45), lineWidth: 1)
                        .accessibilityHidden(true)
                }
            }
    }
}

/// Shares the central capture button's circular accent, without adding a second decorative gradient.
struct ChatSendButton: View {
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.body.weight(.semibold))
                .foregroundStyle(enabled ? Color.white : Color.secondary)
                .frame(width: TouchTarget.comfort, height: TouchTarget.comfort)
                .background(enabled ? Color.accentColor : Color(uiColor: .tertiarySystemFill), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel("Envoyer le message")
    }
}

struct ChatNotice: View {
    let text: String
    var symbol = "info.circle"

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
    }
}

struct ChatProgressLabel: View {
    let text: String
    var body: some View {
        HStack(spacing: Spacing.sm) {
            ProgressView().controlSize(.small)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// Native actions keep full labels. Large text and narrow widths naturally use a column.
struct ChatActions<Content: View>: View {
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
        VStack(alignment: .leading, spacing: Spacing.xs) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EmptyAssistantHint: View {
    let onUseExample: () -> Void
    static let example = "Demain à 17 h, appeler le garage"

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Une chose à prévoir ?")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Écris ou dicte ce que tu veux ajouter, déplacer ou retrouver.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(action: onUseExample) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                    Text(Self.example).fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "arrow.turn.down.left").accessibilityHidden(true)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(minHeight: TouchTarget.comfort, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Utiliser l’exemple : " + Self.example)
            .accessibilityHint("Remplit le brouillon, sans l’envoyer.")
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ChatVoiceDraftContent<Actions: View>: View {
    let duration: String
    let status: String?
    let transcript: String?
    let actions: Actions

    init(duration: String, status: String?, transcript: String?, @ViewBuilder actions: () -> Actions) {
        self.duration = duration
        self.status = status
        self.transcript = transcript
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label {
                Text("Message vocal · \(duration)")
            } icon: {
                Image(systemName: "waveform").foregroundStyle(.secondary)
            }
            .font(.subheadline.weight(.medium))
            .fixedSize(horizontal: false, vertical: true)
            if let status { ChatProgressLabel(text: status) }
            ChatActions(alignment: .leading) { actions }
                .font(.subheadline)
            if let transcript {
                DisclosureGroup("Texte transcrit") {
                    Text(transcript)
                        .font(.subheadline)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, Spacing.xs)
                }
                .font(.footnote)
            }
        }
    }
}

/// Static, anonymous render fixtures of the real content components. The field is a Text stand-in:
/// ImageRenderer cannot validate native text input, keyboard safe areas, focus or system navigation.
struct AssistantChatPreview: View {
    enum Kind: Equatable { case empty, result, proposal, recovery, voice, answer }
    let kind: Kind
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                Spacer()
                Text("Assistant").font(.headline)
                Spacer()
                Image(systemName: "square.and.pencil")
            }
            .padding(Spacing.lg)
            VStack(alignment: .leading, spacing: Spacing.xl) {
                content
            }
            .padding(Spacing.lg)
            Spacer(minLength: Spacing.xl)
            ChatComposerSurface {
                VStack(spacing: Spacing.xs) {
                    if kind == .voice {
                        VoiceRecordingControls(
                            elapsed: 8, levels: [0.2, 0.4, 0.8, 0.3],
                            onCancel: {}, onSend: {}
                        )
                        .padding(Spacing.sm)
                        Divider().padding(.horizontal, Spacing.sm)
                    }
                    if typeSize.isAccessibilitySize {
                        VStack(alignment: .trailing, spacing: 0) {
                            previewField
                            HStack(spacing: Spacing.xs) { previewButtons }
                        }
                    } else {
                        HStack(alignment: .bottom, spacing: Spacing.xs) {
                            previewField
                            previewButtons
                        }
                    }
                }
            }
            .padding(Spacing.md)
        }
        .background(Color(uiColor: .systemBackground))
    }

    @ViewBuilder private var content: some View {
        switch kind {
        case .empty:
            EmptyAssistantHint(onUseExample: {})
        case .result:
            ChatUserBubble(text: "Décale le devoir de maths à demain à 17 h.")
            ChatReplyGroup(style: .result, heading: "Résultat") {
                ReceiptBody(layout: ReceiptLayout(text: "Déplacé : Devoir de maths\nAujourd’hui 18:00 → demain 17:00\nÉchéance inchangée : vendredi\nRappel enregistré. En attente de programmation sur cet iPhone."))
                Divider()
                Label("Devoir de maths", systemImage: "checklist").font(.subheadline)
                Button("Annuler l’action", systemImage: "arrow.uturn.backward", action: {})
                    .font(.subheadline).frame(minHeight: 44)
            }
        case .proposal:
            ChatUserBubble(text: "Supprime les tâches terminées de cette liste.")
            ChatReplyGroup(style: .proposal, heading: "À confirmer") {
                Text("Mettre 2 tâches à la corbeille ?").font(.body.weight(.medium))
                Text("• Relire le chapitre 3\n• Préparer les fiches de révision")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Critère : tâches terminées dans la liste Cours.")
                    .font(.subheadline).foregroundStyle(.secondary)
                ChatActions {
                    Button("Annuler", action: {}).frame(minHeight: 44)
                    Button("Confirmer", action: {}).buttonStyle(.borderedProminent).buttonBorderShape(.capsule).frame(minHeight: 44)
                }
                Text("Expire dans 15 minutes").font(.footnote).foregroundStyle(.secondary)
            }
        case .recovery:
            ChatUserBubble(text: "Ajoute appeler le garage demain à 17 h.")
            ChatNotice(text: "Résultat inconnu. Vérifie la réponse avant de continuer.", symbol: "questionmark.circle")
            Button("Vérifier le résultat", action: {}).frame(minHeight: 44)
            ChatNotice(text: "La connexion a été interrompue. Ton message est gardé.", symbol: "wifi.slash")
        case .voice:
            ChatUserBubble(text: "Prévois 45 minutes pour préparer les fiches demain après-midi.", isVoice: true)
            Label("Vocal · Corriger", systemImage: "waveform").font(.footnote).foregroundStyle(.secondary)
            ChatReplyGroup(style: .question, heading: "À préciser") {
                Text("À quelle heure demain après-midi ?")
                Button("À 14 h", action: {}).frame(minHeight: 44)
                Divider()
                Button("À 16 h", action: {}).frame(minHeight: 44)
            }
        case .answer:
            ChatUserBubble(text: "Quelles tâches sont prévues aujourd’hui ?")
            ChatReplyGroup(style: .text) {
                ChatAssistantText(text: "Voici les tâches prévues aujourd’hui :\n\n• **Préparer le cours** : à 17 h\n• **Appeler le garage** : sans heure\n\nTu peux ouvrir chaque tâche pour voir ses détails.")
            }
        }
    }

    private var previewField: some View {
        Text("Écris une demande…")
            .font(.body)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: TouchTarget.comfort, alignment: .leading)
            .padding(.horizontal, Spacing.md)
    }

    @ViewBuilder private var previewButtons: some View {
        if kind != .voice { Image(systemName: "mic").frame(width: 44, height: 44) }
        ChatSendButton(enabled: false, action: {})
    }
}

#Preview("Assistant · résultat") { AssistantChatPreview(kind: .result) }
#Preview("Assistant · sombre") { AssistantChatPreview(kind: .voice).preferredColorScheme(.dark) }
#Preview("Assistant · grande taille") {
    AssistantChatPreview(kind: .proposal).environment(\.dynamicTypeSize, .accessibility3)
}
#Preview("Assistant · reprise") { AssistantChatPreview(kind: .recovery) }
#Preview("Assistant · vide") { AssistantChatPreview(kind: .empty) }
