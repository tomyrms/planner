import AVFoundation
import Foundation
import Observation

/// Records one voice message as mono AAC (03_iOS/04_Audio_Transcription.md): 2 minutes at most,
/// separate Stop and Cancel, interruptions end the recording without sending anything.
@Observable
final class VoiceRecorder {
    enum Outcome {
        /// A usable file, with its measured duration.
        case finished(URL, durationMs: Int)
        /// Stopped by a call, Siri, a route change or the app leaving the foreground: the user chooses.
        case interrupted(URL, durationMs: Int)
        /// Under a second or silent: nothing is sent.
        case tooShortOrSilent
        case failed
    }

    static let maxDuration: TimeInterval = 120

    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    /// Recent input levels, 0...1, for a secondary waveform.
    private(set) var levels: [Float] = []

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var fileURL: URL?
    @ObservationIgnored private var loudest: Float = -160
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored var onAutomaticStop: ((Outcome) -> Void)?

    static var permission: AVAudioApplication.recordPermission {
        AVAudioApplication.shared.recordPermission
    }

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start(into url: URL) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 22_050,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record(forDuration: Self.maxDuration) else {
            try? session.setActive(false)
            throw CocoaError(.fileWriteUnknown)
        }
        self.recorder = recorder
        fileURL = url
        loudest = -160
        levels = []
        elapsed = 0
        isRecording = true
        startTicker()
        watchInterruptions()
    }

    /// "Arrêter".
    func stop() async -> Outcome {
        await finish(interrupted: false)
    }

    /// "Annuler": the file is deleted.
    func cancel() {
        ticker?.cancel()
        recorder?.stop()
        recorder?.deleteRecording()
        reset()
    }

    /// The app leaves the foreground: keep what was said, let the user choose later.
    func interrupt() async {
        guard isRecording else { return }
        let outcome = await finish(interrupted: true)
        onAutomaticStop?(outcome)
    }

    private func finish(interrupted: Bool) async -> Outcome {
        guard let recorder, let url = fileURL else { return .failed }
        ticker?.cancel()
        let recordedTime = max(recorder.currentTime, elapsed)
        recorder.stop()
        let loudest = self.loudest
        reset()
        let measured = await Self.duration(of: url) ?? recordedTime
        let durationMs = min(120_000, Int((measured * 1000).rounded()))
        // Below 1 s, or never above a whisper: "Aucun son détecté".
        if measured < 1 || loudest < -50 {
            try? FileManager.default.removeItem(at: url)
            return .tooShortOrSilent
        }
        return interrupted ? .interrupted(url, durationMs: durationMs) : .finished(url, durationMs: durationMs)
    }

    private func reset() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        recorder = nil
        fileURL = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startTicker() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let recorder = self.recorder else { return }
                if !recorder.isRecording {
                    // The 2-minute limit stopped the recorder.
                    let outcome = await self.finish(interrupted: false)
                    self.onAutomaticStop?(outcome)
                    return
                }
                recorder.updateMeters()
                let power = recorder.averagePower(forChannel: 0)
                self.loudest = max(self.loudest, recorder.peakPower(forChannel: 0))
                self.elapsed = recorder.currentTime
                let level = max(0, min(1, (power + 50) / 50))
                self.levels = Array((self.levels + [level]).suffix(40))
            }
        }
    }

    private func watchInterruptions() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                Task { await self?.interrupt() }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            MainActor.assumeIsolated {
                Task { await self?.interrupt() }
            }
        })
    }

    private static func duration(of url: URL) async -> TimeInterval? {
        guard let time = try? await AVURLAsset(url: url).load(.duration), time.isNumeric else { return nil }
        return time.seconds
    }
}
