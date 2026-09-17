import SwiftUI
import UIKit

/// Raised central action. Only an active gesture reveals its instructions; it never submits audio.
struct QuickCaptureAccessory: View {
    @Environment(AppServices.self) private var services
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var gesture = QuickCaptureGesture()
    @State private var startTask: Task<Void, Never>?
    @State private var finishTask: Task<Void, Never>?
    @State private var feedbackTask: Task<Void, Never>?
    @State private var captureId: UUID?
    var panelWidth: CGFloat = 300
    let onAddTask: () -> Void
    let onOpenAssistant: () -> Void
    var onCaptureStart: () -> Void = {}

    private var voice: VoiceMessageStore { services.voice }
    private var capturing: Bool { gesture.stage == .holding || gesture.stage == .locked }
    private var finishing: Bool { gesture.stage == .finished || voice.phase == .finishing }

    var body: some View {
        @Bindable var voice = services.voice
        // Keep the touch view at the same structural position for the whole gesture.
            ZStack {
                Circle().fill(Color.accentColor.gradient)
                    .shadow(color: Color.accentColor.opacity(0.22), radius: 5, y: 3)
                Image(systemName: capturing || finishing ? (gesture.stage == .locked ? "lock.fill" : "mic.fill") : "plus")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .offset(
                        x: reduceMotion ? 0 : CGFloat(-gesture.cancelProgress * 5),
                        y: reduceMotion ? 0 : CGFloat(-gesture.lockProgress * 5)
                    )
                    .accessibilityHidden(true)
                Circle()
                    .trim(from: 0, to: CGFloat(gesture.lockProgress))
                    .stroke(Color.primary, lineWidth: 3)
                    .padding(-3)
                    .accessibilityHidden(true)
                QuickCaptureTouchControl(
                    recordingLabel: finishing ? "Finalisation du vocal" : capturing ? (gesture.stage == .locked ? "Enregistrement verrouillé" : "Enregistrement vocal") : nil,
                    onTap: {
                        guard gesture.stage == .idle, !voice.isPreparingRecording, voice.phase != .recording else { return }
                        onAddTask()
                    },
                    onBegin: { begin(locked: false) },
                    onMove: { x, y in
                        if let intent = gesture.move(x: x, y: y), intent == .cancel { cancel() }
                    },
                    onRelease: { if gesture.release() == .finish { finish(interrupted: false) } },
                    onInterrupt: { interrupt() },
                    onAccessibleRecord: { begin(locked: true) }
                )
            }
            .frame(width: 52, height: 52)
        .overlay(alignment: .bottom) {
            if capturing || finishing || gesture.stage == .cancelled {
                capturePanel
                    .frame(width: panelWidth)
                    .padding(.bottom, 68)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: gesture.stage)
        .sensoryFeedback(.impact(weight: .light), trigger: voice.recorder.isRecording)
        .sensoryFeedback(.impact(weight: .medium), trigger: gesture.stage == .locked)
        .sensoryFeedback(.warning, trigger: gesture.stage == .cancelled)
        .onChange(of: voice.phase) { _, phase in
            // Auto-stop at two minutes, calls and route changes also leave a durable draft.
            if phase == .idle, let id = captureId, !voice.isPreparingRecording {
                completeCapture(id: id)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { interrupt() }
        }
        .onDisappear {
            interrupt()
            startTask?.cancel()
            feedbackTask?.cancel()
        }
        .alert("Micro non autorisé", isPresented: $voice.permissionDenied) {
            Button("Ouvrir Réglages") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("Plus tard", role: .cancel) {}
        } message: {
            Text("Le micro sert uniquement aux messages vocaux envoyés à l’assistant. Le texte reste disponible.")
        }
    }

    private var capturePanel: some View {
        VStack(spacing: Spacing.sm) {
            if gesture.stage == .cancelled {
                Label("Vocal annulé", systemImage: "xmark")
            } else {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: gesture.stage == .locked ? "lock.fill" : "record.circle")
                        .foregroundStyle(voice.recorder.isRecording ? Color.red : Color.secondary)
                    Text(voice.isPreparingRecording ? "Micro…" : finishing ? "Finalisation…" : VoiceRecorderBar.clock(voice.recorder.elapsed))
                        .monospacedDigit()
                    VoiceInputLevel(levels: voice.recorder.levels)
                        .frame(width: 42, height: 18)
                        .accessibilityHidden(true)
                }
                if gesture.stage == .locked {
                    HStack(spacing: Spacing.xl) {
                        Button("Annuler", role: .cancel) { cancel() }.frame(minHeight: 44)
                        Button("Arrêter", systemImage: "stop.fill") { finish(interrupted: false) }.frame(minHeight: 44)
                    }
                } else if !finishing {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Spacing.xl) { gestureHints }
                        VStack(spacing: Spacing.sm) { gestureHints }
                    }
                    .font(.caption)
                }
            }
        }
        .font(.subheadline)
        .padding(Spacing.md)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var gestureHints: some View {
        Label("Annuler", systemImage: "arrow.left")
            .foregroundStyle(gesture.cancelProgress > 0 ? Color.orange : Color.secondary)
        Label("Verrouiller", systemImage: "arrow.up")
            .foregroundStyle(gesture.lockProgress > 0 ? Color.accentColor : Color.secondary)
    }

    private func begin(locked: Bool) {
        guard gesture.begin() == .start else { return }
        onCaptureStart()
        let id = UUID()
        captureId = id
        feedbackTask?.cancel()
        if locked { _ = gesture.move(x: 0, y: -80) }
        startTask = Task {
            let started = await voice.startRecording()
            if !started, !Task.isCancelled, captureId == id {
                gesture.reset()
                captureId = nil
                if !voice.permissionDenied { onOpenAssistant() }
            }
            if !Task.isCancelled { startTask = nil }
        }
    }

    private func finish(interrupted: Bool) {
        guard finishTask == nil, let id = captureId else { return }
        gesture.finish()
        startTask?.cancel()
        startTask = nil
        if voice.isPreparingRecording {
            voice.cancelRecording()
            voice.notice = "Enregistrement non démarré. Maintenez à nouveau après avoir autorisé le micro."
            completeCapture(id: id)
            return
        }
        finishTask = Task {
            if interrupted { await voice.appWillResignActive() } else { await voice.stopRecording() }
            guard !Task.isCancelled, captureId == id else { return }
            finishTask = nil
            // Another owner (scene lifecycle/automatic stop) may still be measuring the audio.
            // Keep this capture visible; onChange(.idle) will finish it once the draft is persisted.
            if voice.phase != .finishing { completeCapture(id: id) }
        }
    }

    private func completeCapture(id: UUID) {
        guard captureId == id else { return }
        captureId = nil
        gesture.reset()
        startTask?.cancel()
        startTask = nil
        finishTask = nil
        if voice.draft != nil || voice.notice != nil { onOpenAssistant() }
    }

    private func interrupt() {
        guard gesture.interrupt() != nil else { return }
        finish(interrupted: true)
    }

    private func cancel() {
        captureId = nil
        finishTask?.cancel()
        finishTask = nil
        startTask?.cancel()
        startTask = nil
        voice.cancelRecording()
        // Keep the cancelled state long enough to read; a release cannot turn it into an editor tap.
        if gesture.stage != .cancelled {
            gesture.reset()
            _ = gesture.begin()
            _ = gesture.move(x: -100, y: 0)
        }
        feedbackTask?.cancel()
        feedbackTask = Task {
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            gesture.reset()
            feedbackTask = nil
        }
    }
}
