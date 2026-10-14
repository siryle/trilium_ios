import UIKit
import XCTest
@testable import TriliumPocket

final class KeyboardDismissTests: XCTestCase {
    @MainActor
    func testOnlyTapsOutsideTextInputsInsideSettingsDismissKeyboard() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let region = KeyboardDismissView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        window.addSubview(region)
        defer { region.removeFromSuperview() }
        let location = CGPoint(x: 100, y: 100)

        XCTAssertTrue(region.shouldDismiss(at: location, in: UIView()))
        XCTAssertTrue(region.shouldDismiss(at: location, in: UIButton()))
        XCTAssertFalse(region.shouldDismiss(at: CGPoint(x: 100, y: 750), in: UIView()))

        for input in [UITextField(), UITextView()] as [UIView] {
            let textSubview = UIView()
            input.addSubview(textSubview)
            XCTAssertFalse(region.shouldDismiss(at: location, in: input))
            XCTAssertFalse(region.shouldDismiss(at: location, in: textSubview))
        }

        region.tapRecognizer.isEnabled = false
        XCTAssertFalse(region.shouldDismiss(at: location, in: UIView()))
    }

    @MainActor
    func testDismissRecognizerFollowsWindowAndDoesNotConsumeControlTouches() {
        let firstWindow = UIWindow()
        let secondWindow = UIWindow()
        let region = KeyboardDismissView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        firstWindow.addSubview(region)
        XCTAssertTrue(region.tapRecognizer.view === firstWindow)
        XCTAssertFalse(region.tapRecognizer.cancelsTouchesInView)
        XCTAssertTrue(region.gestureRecognizer(region.tapRecognizer,
                                               shouldRecognizeSimultaneouslyWith: UITapGestureRecognizer()))

        secondWindow.addSubview(region)
        XCTAssertTrue(region.tapRecognizer.view === secondWindow)
        XCTAssertFalse(firstWindow.gestureRecognizers?.contains(region.tapRecognizer) ?? false)

        region.removeFromSuperview()
        XCTAssertNil(region.tapRecognizer.view)
        XCTAssertFalse(region.shouldDismiss(at: CGPoint(x: 50, y: 50), in: UIView()))
    }
}
