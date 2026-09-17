import Testing
import UIKit
@testable import Planner

@MainActor
struct QuickCaptureAccessibilityTests {
    @Test func lockedArrowExposesTheSameOneTimeSendToVoiceOver() {
        var gesture = QuickCaptureGesture()
        _ = gesture.begin()
        _ = gesture.move(x: 0, y: -80)
        #expect(gesture.release() == nil)
        var sends = 0
        let control = QuickCaptureTouchControl(
            recordingLabel: "Enregistrement verrouillé", sendAvailable: true,
            onTap: { if gesture.send() == .send { sends += 1 } },
            onBegin: {}, onMove: { _, _ in }, onRelease: {}, onInterrupt: {}, onAccessibleRecord: {}
        )
        let view = CaptureTouchView(frame: .zero)
        view.actions = control
        view.updateAccessibility(recordingLabel: control.recordingLabel, sendAvailable: control.sendAvailable)
        #expect(view.accessibilityTraits.contains(.button))
        #expect(view.accessibilityLabel == "Envoyer le vocal")
        #expect(view.accessibilityCustomActions?.isEmpty == true)
        let activated = view.accessibilityActivate()
        let activatedAgain = view.accessibilityActivate()
        #expect(activated && activatedAgain)
        #expect(sends == 1)
        #expect(gesture.stage == .finished)
    }

    @Test func preparingPermissionAndFinalizingCannotActivateSend() {
        for label in ["Préparation du micro", "Finalisation du vocal"] {
            var taps = 0
            let control = QuickCaptureTouchControl(
                recordingLabel: label, sendAvailable: false,
                onTap: { taps += 1 }, onBegin: {}, onMove: { _, _ in },
                onRelease: {}, onInterrupt: {}, onAccessibleRecord: {}
            )
            let view = CaptureTouchView(frame: .zero)
            view.actions = control
            view.updateAccessibility(recordingLabel: label, sendAvailable: false)
            let activated = view.accessibilityActivate()
            #expect(!activated)
            #expect(taps == 0)
            #expect(!view.accessibilityTraits.contains(.button))
            #expect(view.accessibilityLabel == label)
        }
    }
}
