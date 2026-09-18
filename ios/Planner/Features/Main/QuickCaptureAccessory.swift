import SwiftUI
import UIKit

/// Raised central action. Releasing a hold or tapping the locked arrow sends, without navigating.
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
    var onCaptureStart: () -> Void = {}
    var onCaptureVisibilityChange: (Bool) -> Void = { _ in }

    private var voice: VoiceMessageStore { services.voice }
    private var capturing: Bool { gesture.stage == .holding || gesture.stage == .locked }
    private var finishing: Bool { gesture.stage == .finished || (captureId != nil && voice.phase == .finishing) }
    private var canSendLocked: Bool {
        gesture.stage == .locked && captureId != nil && finishTask == nil &&
            voice.phase == .recording && voice.recorder.isRecording && !voice.isPreparingRecording && voice.draft == nil
    }

    var body: some View {
        @Bindable var voice = services.voice
        // Keep the touch view at the same structural position for the whole gesture.
            ZStack {
                Circle().fill(Color.accentColor)
                if finishing {
                    ProgressView().tint(.white).accessibilityHidden(true)
                } else {
                    Image(systemName: gesture.stage == .locked ? "arrow.up" : capturing ? "mic.fill" : "plus")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                        .opacity(gesture.stage == .locked && !canSendLocked ? 0.5 : 1)
                        .offset(
                            x: reduceMotion ? 0 : CGFloat(-gesture.cancelProgress * 5),
                            y: reduceMotion ? 0 : CGFloat(-gesture.lockProgress * 5)
                        )
                        .accessibilityHidden(true)
                }
                Circle()
                    .trim(from: 0, to: CGFloat(gesture.lockProgress))
                    .stroke(Color.primary, lineWidth: 3)
                    .padding(-3)
                    .accessibilityHidden(true)
                QuickCaptureTouchControl(
                    recordingLabel: finishing ? "Finalisation du vocal" : capturing ? (voice.isPreparingRecording ? "Préparation du micro" : gesture.stage == .locked ? "Enregistrement verrouillé" : "Enregistrement vocal") : nil,
                    sendAvailable: canSendLocked,
                    onTap: {
                        if gesture.stage == .locked {
                            guard canSendLocked, gesture.send() == .send else { return }
                            finish(interrupted: false, send: true)
                            return
                        }
                        guard gesture.stage == .idle, !voice.isPreparingRecording, voice.phase != .recording else { return }
                        onAddTask()
                    },
                    onBegin: { begin(locked: false) },
                    onMove: { x, y in
                        if let intent = gesture.move(x: x, y: y), intent == .cancel { cancel() }
                    },
                    onRelease: { if gesture.release() == .send { finish(interrupted: false, send: true) } },
                    onInterrupt: { interrupt() },
                    onAccessibleRecord: { begin(locked: true) }
                )
            }
            .frame(width: 52, height: 52)
        .overlay(alignment: .bottom) {
            if capturing || finishing || gesture.stage == .cancelled {
                capturePanel
                    .padding(.bottom, 68)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: gesture.stage)
        .sensoryFeedback(.impact(weight: .light), trigger: voice.recorder.isRecording)
        .sensoryFeedback(.impact(weight: .medium), trigger: gesture.stage == .locked)
        .sensoryFeedback(.warning, trigger: gesture.stage == .cancelled)
        .onChange(of: capturing || finishing, initial: true) { _, visible in
            onCaptureVisibilityChange(visible)
        }
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
            onCaptureVisibilityChange(false)
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

    @ViewBuilder private var capturePanel: some View {
        if gesture.stage == .locked {
            lockedCapture.fixedSize(horizontal: true, vertical: true)
        } else {
            gestureCapture.frame(width: panelWidth)
        }
    }

    /// The raised central arrow remains the only send button after locking.
    private var lockedCapture: some View {
        VoiceRecordingControls(
            elapsed: voice.recorder.elapsed, levels: voice.recorder.levels,
            isLocked: true, isPreparing: voice.isPreparingRecording,
            showsSend: false, canSend: canSendLocked,
            onCancel: { cancel() }, onSend: {
                guard canSendLocked, gesture.send() == .send else { return }
                finish(interrupted: false, send: true)
            }
        )
    }

    private var gestureCapture: some View {
        VStack(spacing: Spacing.sm) {
            if gesture.stage == .cancelled {
                Label("Vocal annulé", systemImage: "xmark")
            } else {
                VoiceRecordingControls(
                    elapsed: voice.recorder.elapsed, levels: voice.recorder.levels,
                    isPreparing: voice.isPreparingRecording, isFinishing: finishing,
                    showsSend: false, canSend: false,
                    onCancel: { cancel() }, onSend: {}
                )
                if !finishing {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Spacing.xl) { gestureHints }
                        VStack(spacing: Spacing.sm) { gestureHints }
                    }
                    .font(.caption)
                }
            }
        }
        .font(.subheadline)
        .padding(.horizontal, Spacing.sm)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var gestureHints: some View {
        Text("Relâcher pour envoyer").foregroundStyle(.secondary)
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
            }
            if !Task.isCancelled { startTask = nil }
        }
    }

    private func finish(interrupted: Bool, send: Bool = false) {
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
            if interrupted {
                await voice.appWillResignActive()
            } else if send {
                // The store owns the consent and the recording identity through finalization.
                // It starts its existing upload operation; the view must never call send() again.
                await voice.stopRecordingAndSend()
            } else {
                await voice.stopRecording()
            }
            guard !Task.isCancelled, captureId == id else { return }
            finishTask = nil
            // Another owner (scene lifecycle/automatic stop) may still be measuring the audio.
            // Keep this capture visible; onChange(.idle) will finish it once the draft is persisted.
            if voice.phase != .finishing && voice.phase != .recording { completeCapture(id: id) }
        }
    }

    private func completeCapture(id: UUID) {
        guard captureId == id else { return }
        captureId = nil
        gesture.reset()
        startTask?.cancel()
        startTask = nil
        finishTask = nil
    }

    private func interrupt() {
        if gesture.stage == .finished, captureId != nil,
           voice.phase == .recording || voice.phase == .finishing || voice.isPreparingRecording {
            // The send tap already ended the gesture, but finalization may still be suspended.
            // Cancel its caller before invalidating the store's intent; if it had not started yet,
            // appWillResignActive still stops the recorder and preserves a draft.
            finishTask?.cancel()
            finishTask = nil
            finish(interrupted: true)
            return
        }
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
