import Foundation

/// UIKit owns touch recognition; this reducer decides the recording gesture exactly once.
nonisolated struct QuickCaptureGesture: Equatable, Sendable {
    enum Stage: Equatable, Sendable { case idle, holding, locked, finished, cancelled }
    enum Intent: Equatable, Sendable { case start, lock, finish, cancel, interrupt }
    private(set) var stage: Stage = .idle
    private(set) var lockProgress: Double = 0
    private(set) var cancelProgress: Double = 0

    mutating func begin() -> Intent? {
        guard stage == .idle else { return nil }
        stage = .holding
        return .start
    }

    mutating func move(x: Double, y: Double) -> Intent? {
        guard stage == .holding else { return nil }
        let left = max(0, -x)
        let up = max(0, -y)
        lockProgress = min(1, up / 80)
        cancelProgress = min(1, left / 100)
        if left >= 100, left > up {
            stage = .cancelled
            return .cancel
        }
        if up >= 80, up > left {
            stage = .locked
            return .lock
        }
        return nil
    }

    mutating func release() -> Intent? {
        guard stage == .holding else { return nil }
        stage = .finished
        return .finish
    }

    mutating func interrupt() -> Intent? {
        guard stage == .holding || stage == .locked else { return nil }
        stage = .finished
        return .interrupt
    }

    mutating func finish() {
        if stage == .holding || stage == .locked { stage = .finished }
    }

    mutating func reset() { self = Self() }
}
