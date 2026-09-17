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
        // UIKit itself may resign the responder while removing it from its window.
        // Keep the probe focused so this specifically exercises the detached-window guard.
        let resignsAfterRemoval = field.resignCount
        field.hasFocus = true
        KeyboardDismissalPolicy.dismiss(captured, in: window)
        #expect(field.resignCount == resignsAfterRemoval)
        #expect(field.hasFocus)
    }

    @Test func theInstallerMovesOnlyItsOwnNonBlockingRecognizerBetweenWindows() throws {
        let first = UIWindow()
        let second = UIWindow()
        let nativeRecognizer = UITapGestureRecognizer()
        first.addGestureRecognizer(nativeRecognizer)
        // UIWindow also owns system gestures (including iOS 26's system gesture gates).
        // Observe their identities instead of assuming that a fresh window is empty.
        let firstNative = recognizerIDs(in: first)
        let secondNative = recognizerIDs(in: second)
        let coordinator = KeyboardDismissalCoordinator()
        coordinator.attach(to: first)
        let ownedRecognizers = first.gestureRecognizers?.filter { $0.delegate === coordinator } ?? []
        #expect(ownedRecognizers.count == 1)
        let installed = try #require(ownedRecognizers.first)
        #expect(!installed.cancelsTouchesInView)
        #expect(!installed.delaysTouchesBegan)
        #expect(!installed.delaysTouchesEnded)
        #expect(coordinator.gestureRecognizer(installed, shouldRecognizeSimultaneouslyWith: nativeRecognizer))
        coordinator.attach(to: first)
        #expect(first.gestureRecognizers?.filter { $0.delegate === coordinator }.count == 1)
        #expect(firstNative.isSubset(of: recognizerIDs(in: first)))

        coordinator.attach(to: second)
        #expect(firstNative.isSubset(of: recognizerIDs(in: first)))
        #expect(!recognizerIDs(in: first).contains(ObjectIdentifier(installed)))
        #expect(installed.view == nil)
        let movedRecognizers = second.gestureRecognizers?.filter { $0.delegate === coordinator } ?? []
        #expect(movedRecognizers.count == 1)
        let moved = try #require(movedRecognizers.first)
        #expect(moved.view === second)
        #expect(secondNative.isSubset(of: recognizerIDs(in: second)))
        coordinator.attach(to: nil)
        #expect(moved.view == nil)
        #expect(second.gestureRecognizers?.contains { $0.delegate === coordinator } != true)
        #expect(firstNative.isSubset(of: recognizerIDs(in: first)))
        #expect(secondNative.isSubset(of: recognizerIDs(in: second)))
    }

    private func recognizerIDs(in window: UIWindow) -> Set<ObjectIdentifier> {
        Set((window.gestureRecognizers ?? []).map(ObjectIdentifier.init))
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
