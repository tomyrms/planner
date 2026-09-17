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
                .font(.title2)
                .frame(minWidth: TouchTarget.comfort, minHeight: TouchTarget.comfort)
        }
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
            VoiceInputLevel(levels: voice.recorder.levels)
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
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack {
                    Label("Message vocal · " + VoiceRecorderBar.clock(TimeInterval(draft.durationMs) / 1000), systemImage: "waveform")
                        .font(.subheadline)
                    Spacer()
                    switch voice.phase {
                    case .checking:
                        ProgressView()
                        Text("Vérification…").font(.footnote)
                    case .uploading:
                        ProgressView()
                        Text("Envoi…").font(.footnote)
                    case .transcribing:
                        ProgressView()
                        Text("Transcription…").font(.footnote)
                    case .delivering:
                        ProgressView()
                        Text("Envoi du texte…").font(.footnote)
                    case .finishing:
                        ProgressView()
                        Text("Finalisation…").font(.footnote)
                    default:
                        if draft.state != .failed || voice.canRetry {
                            Button(draft.transcript != nil ? "Envoyer le texte" : draft.state == .pending ? "Vérifier le résultat" : draft.state == .failed ? "Réessayer" : "Envoyer") {
                                Task {
                                    if draft.state == .pending { await voice.verify() } else { await voice.send() }
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                        Button(draft.state == .failed ? "Écrire à la place" : "Supprimer", role: .destructive) {
                            voice.discard()
                        }
                    }
                }
                if voice.isWorking {
                    Button("Mettre en pause") { voice.pause() }
                        .font(.footnote)
                }
                if let text = draft.transcript {
                    Text(text)
                        .font(.callout)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
            }
        }
    }
}
