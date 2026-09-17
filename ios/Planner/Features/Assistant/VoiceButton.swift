import SwiftUI
import UIKit

/// Accessible alternative to the global hold gesture: tap, then explicit Stop and Send.
struct VoiceButton: View {
    @Environment(AppServices.self) private var services
    @State private var startTask: Task<Void, Never>?

    private var voice: VoiceMessageStore { services.voice }

    var body: some View {
        Button {
            startTask = Task { _ = await voice.startRecording() }
        } label: {
            Image(systemName: "mic")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(minWidth: TouchTarget.comfort, minHeight: TouchTarget.comfort)
        }
        .buttonStyle(.plain)
        .disabled(voice.phase != .idle || voice.isPreparingRecording || voice.draft != nil || !services.assistant.canAcceptVoice)
        .accessibilityLabel("Enregistrer un message vocal")
        .sensoryFeedback(.impact(weight: .light), trigger: voice.phase == .recording)
        .onDisappear {
            startTask?.cancel()
            if voice.isPreparingRecording { voice.cancelRecording() }
        }
    }
}

/// VoiceRecorderBar: duration, "Enregistrement", secondary waveform, separate Arrêter and Annuler.
struct VoiceRecorderBar: View {
    @Environment(AppServices.self) private var services

    private var voice: VoiceMessageStore { services.voice }

    var body: some View {
        ChatRecordingBar(
            elapsed: voice.recorder.elapsed, levels: voice.recorder.levels,
            onCancel: { voice.cancelRecording() },
            onStop: { Task { await voice.stopRecording() } }
        )
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return "\(total / 60):" + (total % 60 < 10 ? "0" : "") + "\(total % 60)"
    }
}

struct VoiceInputLevel: View {
    let levels: [Float]

    var body: some View {
        GeometryReader { geometry in
            let visibleCount = max(1, Int((max(0, geometry.size.width) + 2) / 4))
            let visibleLevels = Array(levels.suffix(visibleCount))
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(visibleLevels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(Color.secondary)
                        .frame(width: 2, height: max(2, geometry.size.height * CGFloat(level)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .clipped()
        }
    }
}

/// A recorded message not yet turned into text: interrupted, offline or failed.
struct VoiceDraftBar: View {
    @Environment(AppServices.self) private var services

    private var voice: VoiceMessageStore { services.voice }

    var body: some View {
        if let draft = voice.draft {
            ChatVoiceDraftContent(
                duration: VoiceRecorderBar.clock(TimeInterval(draft.durationMs) / 1000),
                status: status, transcript: draft.transcript
            ) {
                if voice.isWorking {
                    Button("Mettre en pause") { voice.pause() }
                        .frame(minHeight: TouchTarget.comfort)
                } else {
                    if draft.state != .failed || voice.canRetry {
                        Button(draft.transcript != nil ? "Envoyer le texte" : draft.state == .pending ? "Vérifier le résultat" : draft.state == .failed ? "Réessayer" : "Envoyer le vocal") {
                            Task {
                                if draft.state == .pending { await voice.verify() } else { await voice.send() }
                            }
                        }
                        .frame(minHeight: TouchTarget.comfort)
                    }
                    Button(draft.state == .failed ? "Écrire à la place" : "Supprimer", role: .destructive) { voice.discard() }
                        .frame(minHeight: TouchTarget.comfort)
                }
            }
        }
    }

    private var status: String? {
        switch voice.phase {
        case .checking: "Vérification…"
        case .uploading: "Envoi…"
        case .transcribing: "Transcription…"
        case .delivering: "Envoi du texte…"
        case .finishing: "Finalisation…"
        default: nil
        }
    }
}
