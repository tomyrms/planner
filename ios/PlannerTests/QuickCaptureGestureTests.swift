import Testing
@testable import Planner

struct QuickCaptureGestureTests {
    @Test func releaseBeforeRecognizedHoldDoesNotStartOrFinishAVocal() {
        var gesture = QuickCaptureGesture()
        #expect(gesture.release() == nil)
        #expect(gesture.stage == .idle)
    }

    @Test func aHoldStartsAndFinishesOnlyOnce() {
        var gesture = QuickCaptureGesture()
        #expect(gesture.begin() == .start)
        #expect(gesture.begin() == nil)
        #expect(gesture.release() == .finish)
        #expect(gesture.release() == nil)
        #expect(gesture.stage == .finished)
    }

    @Test func upwardGestureLocksAndReleaseKeepsTheRecording() {
        var gesture = QuickCaptureGesture()
        _ = gesture.begin()
        #expect(gesture.move(x: -10, y: -40) == nil)
        #expect(gesture.lockProgress == 0.5)
        #expect(gesture.move(x: -10, y: -80) == .lock)
        #expect(gesture.stage == .locked)
        #expect(gesture.release() == nil)
        #expect(gesture.move(x: -200, y: 0) == nil)
    }

    @Test func leftGestureCancelsAndReleaseCannotFinishIt() {
        var gesture = QuickCaptureGesture()
        _ = gesture.begin()
        #expect(gesture.move(x: -50, y: -10) == nil)
        #expect(gesture.cancelProgress == 0.5)
        #expect(gesture.move(x: -100, y: -10) == .cancel)
        #expect(gesture.release() == nil)
        #expect(gesture.stage == .cancelled)
    }

    @Test func dominantDirectionDecidesDiagonalGestures() {
        var gesture = QuickCaptureGesture()
        _ = gesture.begin()
        #expect(gesture.move(x: -100, y: -100) == nil)
        #expect(gesture.move(x: -120, y: -110) == .cancel)
        gesture.reset()
        _ = gesture.begin()
        #expect(gesture.move(x: -110, y: -120) == .lock)
    }

    @Test func interruptionEndsLockedRecordingOnlyOnce() {
        var gesture = QuickCaptureGesture()
        _ = gesture.begin()
        _ = gesture.move(x: 0, y: -80)
        #expect(gesture.interrupt() == .interrupt)
        #expect(gesture.interrupt() == nil)
        #expect(gesture.release() == nil)
        gesture.reset()
        #expect(gesture.stage == .idle)
        #expect(gesture.lockProgress == 0)
        #expect(gesture.begin() == .start)
    }

    @Test func stopLeavesTheLockedStateBeforeAsynchronousFinalization() {
        var gesture = QuickCaptureGesture()
        _ = gesture.begin()
        _ = gesture.move(x: 0, y: -80)
        gesture.finish()
        #expect(gesture.stage == .finished)
        #expect(gesture.release() == nil)
        #expect(gesture.interrupt() == nil)
        gesture.finish()
        #expect(gesture.stage == .finished)
    }
}
