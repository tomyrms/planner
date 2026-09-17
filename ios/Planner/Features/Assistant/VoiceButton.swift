import SwiftUI
import UIKit

/// Microphone of the composer: one tap starts a recording (hold-to-talk is LATER).
struct VoiceButton: View {
    @Environment(AppServices.self) private var services

    private var voice: VoiceMessageStore { services.voice }

    var body: some View {
        @Bindable var voice = services.voice
        Button {
            Task { await voice.startRecording() }
        } label: {
            Image(systemName: "mic")
                .font(.title2)
                .frame(minWidth: TouchTarget.comfort, minHeight: TouchTarget.comfort)
        }
        .disabled(voice.phase != .idle || voice.draft != nil || services.assistant.isBusy || services.assistant.pending != nil)
        .accessibilityLabel("Enregistrer un message vocal")
        .sensoryFeedback(.impact(weight: .light), trigger: voice.phase == .recording)
        .alert("Micro non autorisé", isPresented: $voice.permissionDenied) {
            Button("Ouvrir Réglages") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("Plus tard", role: .cancel) {}
        } message: {
            Text("Le micro sert uniquement à enregistrer les messages vocaux envoyés à l’assistant. Le texte reste toujours disponible.")
        }
    }
}

/// VoiceRecorderBar: duration, "Enregistrement", secondary waveform, separate Arrêter and Annuler.
struct VoiceRecorderBar: View {
    @Environment(AppServices.self) private var services

    private var voice: VoiceMessageStore { services.voice }

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "record.circle")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Enregistrement")
                    .font(.subheadline.weight(.semibold))
                Text(Self.clock(voice.recorder.elapsed) + " / 2:00")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Waveform(levels: voice.recorder.levels)
                .frame(height: 24)
                .accessibilityHidden(true)
            Button("Annuler", role: .cancel) { voice.cancelRecording() }
            Button("Arrêter") {
                Task { await voice.stopRecording() }
            }
            .buttonStyle(.borderedProminent)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Enregistrement en cours, " + Self.clock(voice.recorder.elapsed))
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return "\(total / 60):" + (total % 60 < 10 ? "0" : "") + "\(total % 60)"
    }
}

private struct Waveform: View {
    let levels: [Float]

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(Color.secondary)
                        .frame(width: 2, height: max(2, geometry.size.height * CGFloat(level)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
    }
}

/// A recorded message not yet turned into text: interrupted, offline or failed.
struct VoiceDraftBar: View {
    @Environment(AppServices.self) private var services

    private var voice: VoiceMessageStore { services.voice }

    var body: some View {
        if let draft = voice.draft {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack {
                    Label("Message vocal · " + VoiceRecorderBar.clock(TimeInterval(draft.durationMs) / 1000), systemImage: "waveform")
                        .font(.subheadline)
                    Spacer()
                    switch voice.phase {
                    case .uploading:
                        ProgressView()
                        Text("Envoi…").font(.footnote)
                    case .transcribing:
                        ProgressView()
                        Text("Transcription…").font(.footnote)
                    default:
                        if draft.state != .failed || voice.canRetry {
                            Button(draft.state == .failed ? "Réessayer" : "Envoyer") {
                                Task { await voice.send() }
                            }
                            .buttonStyle(.bordered)
                        }
                        Button(draft.state == .failed ? "Écrire à la place" : "Supprimer", role: .destructive) {
                            voice.discard()
                        }
                    }
                }
            }
        }
    }
}
