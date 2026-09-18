import SwiftUI

/// Shared by the global capture and assistant composer. Only the location of Send differs:
/// the global capture already has its raised central arrow, so it does not duplicate that action.
struct VoiceRecordingControls: View {
    let elapsed: TimeInterval
    let levels: [Float]
    var isLocked = false
    var isPreparing = false
    var isFinishing = false
    var showsSend = true
    var canSend = true
    let onCancel: () -> Void
    let onSend: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Button(role: .cancel, action: onCancel) {
                Image(systemName: "trash")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: TouchTarget.comfort, height: TouchTarget.comfort)
            }
            .buttonStyle(.plain)
            .disabled(isFinishing)
            .accessibilityLabel("Annuler le vocal")
            .accessibilityHint("Supprime cet enregistrement sans l’envoyer")

            Image(systemName: isLocked ? "lock.fill" : "mic.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(isPreparing ? "Micro…" : VoiceRecorderBar.clock(elapsed))
                .font(.subheadline.monospacedDigit())
                .lineLimit(1)
                .fixedSize()
                .accessibilityLabel("Durée du vocal")
                .accessibilityValue(VoiceRecorderBar.clock(elapsed))
            if !typeSize.isAccessibilitySize && !reduceMotion {
                VoiceInputLevel(levels: levels)
                    .frame(width: 36, height: 18)
                    .accessibilityHidden(true)
            }
            if isFinishing {
                ProgressView().controlSize(.small)
                    .frame(width: TouchTarget.comfort, height: TouchTarget.comfort)
                    .accessibilityLabel("Finalisation du vocal")
            } else if showsSend {
                ChatSendButton(enabled: canSend && !isPreparing, action: onSend)
                    .accessibilityLabel("Envoyer le vocal")
                    .accessibilityHint("Arrête et envoie le vocal sans confirmation supplémentaire")
            }
        }
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, Spacing.xs)
        .background {
            if reduceTransparency {
                Capsule().fill(Color(uiColor: .secondarySystemBackground))
            } else {
                Capsule().fill(.regularMaterial)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isLocked ? "Enregistrement verrouillé" : "Enregistrement vocal")
    }
}

#Preview("Vocal du chat") {
    VoiceRecordingControls(elapsed: 12, levels: [0.2, 0.4, 0.8, 0.3], onCancel: {}, onSend: {})
        .padding()
}
#Preview("Vocal verrouillé") {
    VoiceRecordingControls(elapsed: 12, levels: [0.2, 0.4, 0.8, 0.3], isLocked: true, showsSend: false, onCancel: {}, onSend: {})
        .padding()
}
