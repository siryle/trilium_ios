import SwiftUI
import UIKit

struct KeyboardDismissOnTap: UIViewRepresentable {
    var isEnabled: Bool
    var dismiss: () -> Void

    func makeUIView(context: Context) -> KeyboardDismissView {
        KeyboardDismissView()
    }

    func updateUIView(_ view: KeyboardDismissView, context: Context) {
        view.tapRecognizer.isEnabled = isEnabled
        view.dismiss = dismiss
    }

    static func dismantleUIView(_ view: KeyboardDismissView, coordinator: ()) {
        view.tapRecognizer.view?.removeGestureRecognizer(view.tapRecognizer)
        view.dismiss = nil
    }
}

final class KeyboardDismissView: UIView, UIGestureRecognizerDelegate {
    var dismiss: (() -> Void)?
    let tapRecognizer = UITapGestureRecognizer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        tapRecognizer.cancelsTouchesInView = false
        tapRecognizer.delegate = self
        tapRecognizer.addTarget(self, action: #selector(dismissKeyboard))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        tapRecognizer.view?.removeGestureRecognizer(tapRecognizer)
        window?.addGestureRecognizer(tapRecognizer)
    }

    func shouldDismiss(at location: CGPoint, in touchedView: UIView?) -> Bool {
        guard tapRecognizer.isEnabled, window != nil, bounds.contains(location) else { return false }
        // Preserve text selection and focus when tapping either input field.
        var ancestor = touchedView
        while let view = ancestor {
            if view is UITextField || view is UITextView { return false }
            ancestor = view.superview
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        shouldDismiss(at: touch.location(in: self), in: touch.view)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    @objc private func dismissKeyboard() { dismiss?() }
}
