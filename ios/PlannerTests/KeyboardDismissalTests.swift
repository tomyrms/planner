import Testing
import UIKit
@testable import Planner

@MainActor
struct KeyboardDismissalTests {
    @Test func nativeInputsControlsAndTheirInternalSubviewsKeepTheirTouches() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        let background = UIView()
        window.addSubview(background)
        #expect(KeyboardDismissalPolicy.acceptsTouch(on: background, in: window))

        let textField = UITextField()
        let secureField = UITextField()
        secureField.isSecureTextEntry = true
        let editor = UITextView()
        let search = UISearchTextField()
        let button = UIButton(type: .system)
        let toggle = UISwitch()
        for control in [textField, secureField, editor, search, button, toggle] as [UIView] {
            background.addSubview(control)
            let internalSubview = UIView()
            control.addSubview(internalSubview)
            #expect(!KeyboardDismissalPolicy.acceptsTouch(on: control, in: window))
            #expect(!KeyboardDismissalPolicy.acceptsTouch(on: internalSubview, in: window))
        }
        #expect(!KeyboardDismissalPolicy.acceptsTouch(on: nil, in: window))
        #expect(!KeyboardDismissalPolicy.acceptsTouch(on: UIView(), in: window))
    }

    @Test func aNewlyFocusedFieldIsNeverDismissedByAnEarlierBackgroundTap() {
        let window = UIWindow()
        let original = KeyboardInputProbe()
        let next = KeyboardInputProbe()
        window.addSubview(original)
        window.addSubview(next)
        original.hasFocus = true
        let captured = KeyboardDismissalPolicy.activeTextInput(in: window)
        #expect(captured === original)

        // A button/native control changes focus while its tap is being delivered.
        original.hasFocus = false
        next.hasFocus = true
        KeyboardDismissalPolicy.dismiss(captured, in: window)
        #expect(original.resignCount == 0)
        #expect(next.resignCount == 0)
        #expect(next.hasFocus)
    }

    @Test func backgroundTapResignsOnlyTheOriginalAttachedInputWithoutChangingItsText() {
        let window = UIWindow()
        let field = KeyboardInputProbe()
        window.addSubview(field)
        field.text = "Brouillon conservé"
        field.hasFocus = true
        let captured = KeyboardDismissalPolicy.activeTextInput(in: window)
        KeyboardDismissalPolicy.dismiss(captured, in: window)
        #expect(field.resignCount == 1)
        #expect(!field.hasFocus)
        #expect(field.text == "Brouillon conservé")

        field.hasFocus = true
        field.removeFromSuperview() // A sheet closed before the deferred tap callback.
        KeyboardDismissalPolicy.dismiss(captured, in: window)
        #expect(field.resignCount == 1)
    }

    @Test func theInstallerMovesOnlyItsOwnNonBlockingRecognizerBetweenWindows() throws {
        let first = UIWindow()
        let second = UIWindow()
        let nativeRecognizer = UITapGestureRecognizer()
        first.addGestureRecognizer(nativeRecognizer)
        let coordinator = KeyboardDismissalCoordinator()
        coordinator.attach(to: first)
        let installed = try #require(first.gestureRecognizers?.first { $0 !== nativeRecognizer })
        #expect(!installed.cancelsTouchesInView)
        #expect(!installed.delaysTouchesBegan)
        #expect(!installed.delaysTouchesEnded)
        #expect(coordinator.gestureRecognizer(installed, shouldRecognizeSimultaneouslyWith: nativeRecognizer))
        coordinator.attach(to: first)
        #expect(first.gestureRecognizers?.count == 2)

        coordinator.attach(to: second)
        #expect(first.gestureRecognizers?.count == 1)
        #expect(first.gestureRecognizers?.first === nativeRecognizer)
        #expect(second.gestureRecognizers?.count == 1)
        coordinator.attach(to: nil)
        #expect(second.gestureRecognizers?.isEmpty ?? true)
        #expect(first.gestureRecognizers?.first === nativeRecognizer)
    }
}

/// Focus-state probe avoids opening a real keyboard or changing the simulator's foreground window.
/// Hit-testing tests above still use the actual UIKit classes used by SwiftUI inputs and controls.
@MainActor
private final class KeyboardInputProbe: UITextField {
    var hasFocus = false
    var resignCount = 0
    override var isFirstResponder: Bool { hasFocus }
    override func resignFirstResponder() -> Bool {
        resignCount += 1
        hasFocus = false
        return true
    }
}
