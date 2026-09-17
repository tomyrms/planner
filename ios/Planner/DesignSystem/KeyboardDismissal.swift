import SwiftUI
import UIKit

extension View {
    /// Install once at the scene root. The same window also contains this scene's native sheets.
    func dismissKeyboardOnBackgroundTap() -> some View {
        background {
            KeyboardDismissalInstaller()
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}

/// UIKit hit testing preserves text selection and field-to-field focus, including SwiftUI's
/// TextField, SecureField, TextEditor and the search field's internal native subviews.
enum KeyboardDismissalPolicy {
    static func acceptsTouch(on touchedView: UIView?, in window: UIWindow) -> Bool {
        guard let touchedView, touchedView.isDescendant(of: window) else { return false }
        var ancestor: UIView? = touchedView
        while let view = ancestor {
            if view is UIControl || view is any UITextInput { return false }
            if view === window { return true }
            ancestor = view.superview
        }
        return false
    }

    static func activeTextInput(in root: UIView) -> UIView? {
        if root.isFirstResponder, root is any UITextInput { return root }
        for child in root.subviews {
            if let input = activeTextInput(in: child) { return input }
        }
        return nil
    }

    static func dismiss(_ originalInput: UIView?, in window: UIWindow) {
        guard let originalInput, originalInput.window === window, originalInput.isFirstResponder else { return }
        // Never endEditing on the window: a native button or tap may have focused another field.
        _ = originalInput.resignFirstResponder()
    }
}

final class KeyboardDismissalCoordinator: NSObject, UIGestureRecognizerDelegate {
    private weak var window: UIWindow?
    private weak var originalInput: UIView?
    private var recognizer: UITapGestureRecognizer?

    func attach(to nextWindow: UIWindow?) {
        guard window !== nextWindow else { return }
        if let recognizer { window?.removeGestureRecognizer(recognizer) }
        recognizer = nil
        originalInput = nil
        window = nextWindow
        guard let nextWindow else { return }

        let tap = UITapGestureRecognizer(target: self, action: #selector(receivedTap))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = self
        nextWindow.addGestureRecognizer(tap)
        recognizer = tap
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        originalInput = nil
        guard let window, KeyboardDismissalPolicy.acceptsTouch(on: touch.view, in: window) else { return false }
        originalInput = KeyboardDismissalPolicy.activeTextInput(in: window)
        return originalInput != nil
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool { true }

    @objc private func receivedTap(_ sender: UITapGestureRecognizer) {
        guard sender.state == .ended else { return }
        let candidate = originalInput
        let owningWindow = window
        originalInput = nil
        // Let the native tap/button finish first; only the responder captured at touch-down can
        // be dismissed. Weak references make a closed sheet or replaced window a harmless no-op.
        DispatchQueue.main.async { [weak candidate, weak owningWindow] in
            guard let owningWindow else { return }
            KeyboardDismissalPolicy.dismiss(candidate, in: owningWindow)
        }
    }
}

private struct KeyboardDismissalInstaller: UIViewRepresentable {
    func makeCoordinator() -> KeyboardDismissalCoordinator { KeyboardDismissalCoordinator() }

    func makeUIView(context: Context) -> WindowObserver {
        let view = WindowObserver()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.windowChanged = { [weak coordinator = context.coordinator] window in coordinator?.attach(to: window) }
        return view
    }

    func updateUIView(_ uiView: WindowObserver, context: Context) { context.coordinator.attach(to: uiView.window) }

    static func dismantleUIView(_ uiView: WindowObserver, coordinator: KeyboardDismissalCoordinator) {
        uiView.windowChanged = nil
        coordinator.attach(to: nil)
    }

    final class WindowObserver: UIView {
        var windowChanged: (@MainActor (UIWindow?) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            windowChanged?(window)
        }
    }
}
