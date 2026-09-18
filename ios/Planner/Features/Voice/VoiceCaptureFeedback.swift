import SwiftUI

/// Status, not navigation. A saved/failed vocal remains discoverable outside the assistant tab.
/// Neither this view nor its disappearance owns/cancels the store's network operation.
struct VoiceCaptureFeedback: View {
    @Environment(AppServices.self) private var services
    @State private var dismissedStatus: Status?
    let onOpenAssistant: () -> Void

    private struct Status: Equatable {
        let text: String
        var working = false
        var identity = ""
    }

    var body: some View {
        if let status, status != dismissedStatus {
            HStack(spacing: Spacing.sm) {
                if status.working {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                } else {
                    Image(systemName: "waveform").foregroundStyle(.secondary).accessibilityHidden(true)
                }
                Text(status.text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Voir", action: onOpenAssistant)
                    .font(.subheadline)
                    .frame(minWidth: TouchTarget.comfort, minHeight: TouchTarget.comfort)
                    .accessibilityLabel("Ouvrir le vocal dans l’assistant")
                Button { dismissedStatus = status } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.medium))
                        .frame(width: TouchTarget.comfort, height: TouchTarget.comfort)
                }
                .accessibilityLabel("Masquer l’état du vocal")
                .accessibilityHint("Le traitement continue et le vocal reste disponible dans l’assistant")
            }
            .buttonStyle(.plain)
            .padding(.leading, Spacing.md)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.medium))
            .accessibilityElement(children: .contain)
        }
    }

    private var status: Status? {
        let voice = services.voice
        let identity = voice.draft?.transcriptionId ?? ""
        switch voice.phase {
        case .recording, .finishing: return nil
        case .checking: return Status(text: "Vérification du vocal…", working: true, identity: identity)
        case .uploading: return Status(text: "Envoi du vocal…", working: true, identity: identity)
        case .transcribing: return Status(text: "Transcription du vocal…", working: true, identity: identity)
        case .delivering: return Status(text: "Transmission à l’assistant…", working: true, identity: identity)
        case .idle: break
        }
        if voice.isPreparingRecording { return nil }
        if let notice = voice.notice { return Status(text: notice, identity: identity) }
        if voice.draft != nil { return Status(text: "Vocal conservé. Vous pouvez le reprendre.", identity: identity) }

        let assistant = services.assistant
        if let pending = assistant.pending, pending.transcriptionId != nil {
            switch assistant.phase {
            case .preparing, .waiting:
                return Status(text: "L’assistant traite le vocal…", working: true, identity: pending.turnId)
            case .offline, .notReceived:
                return Status(text: "Message conservé. L’envoi doit être repris.", identity: pending.turnId)
            case .unknown:
                return Status(text: "Résultat à vérifier. Ne renvoyez pas le vocal.", identity: pending.turnId)
            case .refused:
                return Status(text: "Message conservé. Une action est nécessaire.", identity: pending.turnId)
            case .idle: break
            }
        }
        // Do not claim a task was created or modified merely because audio was sent.
        return nil
    }
}
