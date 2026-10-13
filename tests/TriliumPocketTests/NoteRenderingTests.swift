import Combine
import UIKit
import WebKit
import XCTest
@testable import TriliumPocket

final class NoteRenderingTests: XCTestCase {
    @MainActor
    func testUnicodeHTMLRendersAfterInitialization() async throws {
        let renderer = try Renderer(content: "<p>你好 &amp; hello</p>")
        defer { renderer.close() }
        try await waitForRender(renderer.bridge)

        let text = try await renderer.web.evaluateJavaScript("document.getElementById('note').textContent")
        XCTAssertEqual(text as? String, "你好 & hello")
        XCTAssertGreaterThan(renderer.web.bounds.width, 0)
        XCTAssertGreaterThan(renderer.web.bounds.height, 0)
        XCTAssertTrue(renderer.bridge.ready)
        XCTAssertNil(renderer.bridge.displayError)
    }

    @MainActor
    func testUntouchedEditableDocumentDoesNotRewriteSource() async throws {
        let source = "<p class='custom'>你好 <strong>world</strong> &amp; friends</p>"
        let renderer = try Renderer(content: source, editing: true)
        defer { renderer.close() }
        try await waitForRender(renderer.bridge)

        let editable = try await renderer.web.evaluateJavaScript("document.getElementById('note').isContentEditable")
        XCTAssertEqual(editable as? Bool, true)
        let changedContent = try await renderer.bridge.flush()
        XCTAssertNil(changedContent, "Entering the editor and flushing must preserve the original HTML until actual edits occur.")
        XCTAssertEqual(renderer.view.content, source)
    }

    @MainActor
    func testSanitizationRetainsTextWithoutExecutingUntrustedScript() async throws {
        let source = """
        <script>window.untrustedExecuted = true;</script>
        <p onclick="window.untrustedExecuted = true">可见正文</p>
        <a href="javascript:window.untrustedExecuted=true">链接文字</a>
        """
        let renderer = try Renderer(content: source)
        defer { renderer.close() }
        try await waitForRender(renderer.bridge)

        let result = try await renderer.web.evaluateJavaScript("""
        (() => {
          const article = document.getElementById('note');
          article.querySelector('p').click();
          return {
            text: article.textContent,
            scriptCount: article.querySelectorAll('script').length,
            eventCount: article.querySelectorAll('[onclick]').length,
            unsafeLinkCount: article.querySelectorAll('a[href]').length,
            executed: window.untrustedExecuted === true
          };
        })()
        """)
        let values = try XCTUnwrap(result as? [String: Any])
        XCTAssertTrue((values["text"] as? String)?.contains("可见正文") == true)
        XCTAssertTrue((values["text"] as? String)?.contains("链接文字") == true)
        XCTAssertEqual((values["scriptCount"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual((values["eventCount"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual((values["unsafeLinkCount"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual((values["executed"] as? NSNumber)?.boolValue, false)
    }

    @MainActor
    private func waitForRender(_ bridge: WebEditorBridge) async throws {
        let finished = expectation(description: "Renderer finishes bootstrap and initial content injection")
        // Subscribe before yielding to WebKit; a ready renderer also completes immediately.
        let observation = bridge.$isLoading.filter { !$0 }.prefix(1).sink { _ in finished.fulfill() }
        await fulfillment(of: [finished], timeout: 20)
        observation.cancel()
        XCTAssertFalse(bridge.isLoading)
        XCTAssertNil(bridge.displayError)
        guard bridge.ready else {
            throw UserFacingError(message: bridge.displayError ?? "WebKit renderer did not become ready.")
        }
    }
}

/// Retain the coordinator and a visible native viewport until asynchronous WebKit work completes.
@MainActor
private final class Renderer {
    let view: NoteWebView
    let coordinator: NoteWebView.Coordinator
    let bridge: WebEditorBridge
    let web: WKWebView
    let window: UIWindow
    private let controller: UIViewController

    init(content: String, editing: Bool = false) throws {
        let bridge = WebEditorBridge()
        let api = APIClient(baseURL: try XCTUnwrap(URL(string: "https://rendering.invalid")), token: "unused-test-token")
        let view = NoteWebView(content: content, editing: editing, api: api, bridge: bridge,
                               command: nil, onChange: { _ in }, onNoteLink: { _ in })
        let coordinator = view.makeCoordinator()
        let web = view.makeWebView(coordinator: coordinator)
        let frame = CGRect(x: 0, y: 0, width: 390, height: 640)
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
            window.frame = frame
        } else {
            window = UIWindow(frame: frame)
        }
        let controller = UIViewController()
        window.rootViewController = controller
        controller.loadViewIfNeeded()
        controller.view.frame = frame
        web.frame = controller.view.bounds
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(web)
        window.isHidden = false
        controller.view.layoutIfNeeded()
        self.bridge = bridge
        self.view = view
        self.coordinator = coordinator
        self.web = web
        self.window = window
        self.controller = controller
    }

    func close() {
        web.stopLoading()
        NoteWebView.dismantleUIView(web, coordinator: coordinator)
        web.navigationDelegate = nil
        web.removeFromSuperview()
        window.isHidden = true
        window.rootViewController = nil
    }
}
