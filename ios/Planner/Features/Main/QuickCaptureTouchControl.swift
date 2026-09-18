import SwiftUI
import UIKit

/// A native recognizer avoids firing a tap when a long press ends, including outside the 44 pt target.
struct QuickCaptureTouchControl: UIViewRepresentable {
    var recordingLabel: String?
    var sendAvailable = false
    var onTap: () -> Void
    var onBegin: () -> Void
    var onMove: (Double, Double) -> Void
    var onRelease: () -> Void
    var onInterrupt: () -> Void
    var onAccessibleRecord: () -> Void

    func makeUIView(context: Context) -> CaptureTouchView { CaptureTouchView() }

    func updateUIView(_ view: CaptureTouchView, context: Context) {
        view.actions = self
        view.updateAccessibility(recordingLabel: recordingLabel, sendAvailable: sendAvailable)
    }

    static func dismantleUIView(_ view: CaptureTouchView, coordinator: ()) {
        view.interruptIfNeeded()
    }
}

final class CaptureTouchView: UIView {
    var actions: QuickCaptureTouchControl?
    private var origin: CGPoint?
    private var tracking = false
    private let hold = UILongPressGestureRecognizer()
    private let tap = UITapGestureRecognizer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        hold.minimumPressDuration = 0.35
        hold.allowableMovement = 20
        hold.numberOfTouchesRequired = 1
        hold.addTarget(self, action: #selector(held(_:)))
        tap.require(toFail: hold)
        tap.addTarget(self, action: #selector(tapped))
        addGestureRecognizer(hold)
        addGestureRecognizer(tap)
        isAccessibilityElement = true
        updateAccessibility(recordingLabel: nil)
    }

    required init?(coder: NSCoder) { nil }

    func updateAccessibility(recordingLabel: String?, sendAvailable: Bool = false) {
        accessibilityTraits = recordingLabel == nil || sendAvailable ? .button : .staticText
        accessibilityLabel = sendAvailable ? "Envoyer le vocal" : recordingLabel ?? "Ajouter une tâche"
        if sendAvailable {
            accessibilityHint = "Arrête et envoie le vocal sans changer d’écran."
        } else {
            accessibilityHint = recordingLabel == nil
                ? "Touchez pour écrire une tâche. Maintenez pour dicter et relâchez pour envoyer. L’action Enregistrer un vocal permet de dicter sans maintenir."
                : "Relâchez pour envoyer, glissez à gauche pour annuler ou vers le haut pour verrouiller."
        }
        accessibilityCustomActions = recordingLabel == nil ? [
            UIAccessibilityCustomAction(name: "Enregistrer un vocal") { [weak self] _ in
                self?.actions?.onAccessibleRecord()
                return true
            },
        ] : []
    }

    override func accessibilityActivate() -> Bool {
        guard let actions, actions.recordingLabel == nil || actions.sendAvailable else { return false }
        actions.onTap()
        return true
    }

    @objc private func tapped() { actions?.onTap() }

    @objc private func held(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            tracking = true
            origin = recognizer.location(in: window)
            actions?.onBegin()
        case .changed:
            guard tracking, let origin else { return }
            let point = recognizer.location(in: window)
            actions?.onMove(Double(point.x - origin.x), Double(point.y - origin.y))
        case .ended:
            guard tracking else { return }
            tracking = false
            origin = nil
            actions?.onRelease()
        case .cancelled, .failed:
            interruptIfNeeded()
        default:
            break
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if (event?.allTouches?.count ?? touches.count) > 1 {
            interruptIfNeeded()
            hold.isEnabled = false
            hold.isEnabled = true
            tap.isEnabled = false
            tap.isEnabled = true
        }
        super.touchesBegan(touches, with: event)
    }

    func interruptIfNeeded() {
        guard tracking else { return }
        tracking = false
        origin = nil
        actions?.onInterrupt()
    }
}
