import Foundation
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import TriliumPocket

/// Exercise the real SwiftUI detail lifecycle, including an initially unloaded editor.
final class NoteDetailPresentationTests: XCTestCase {
    @MainActor
    func testFreshDetailLoadsAndDisplaysChineseBodyInItsActualViewport() async throws {
        let fixture = try PresentationFixture()
        defer { fixture.close() }
        let model = AppModel(client: fixture.api)
        let editor = model.editor(for: "renderNote")
        XCTAssertNil(editor.note, "Do not preload the editor: mounting the detail must start its task.")
        XCTAssertFalse(editor.loading)
        let host = DetailHost(model: model)
        defer { host.close() }

        let web = try await waitForBody(in: host, expected: "首次打开：你好 & hello")

        XCTAssertEqual(editor.note?.id, "renderNote")
        XCTAssertEqual(editor.content, PresentationFixture.body)
        XCTAssertFalse(editor.loading)
        XCTAssertNil(editor.failure)
        XCTAssertGreaterThan(web.bounds.width, 0)
        XCTAssertGreaterThan(web.bounds.height, 0)
        XCTAssertFalse(web.isHidden)
        XCTAssertGreaterThan(web.alpha, 0)
        let requests = fixture.requests
        XCTAssertEqual(requests.map { $0.url?.path }, ["/trilium/etapi/notes/renderNote", "/trilium/etapi/notes/renderNote/content"])
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "presentation-test-token" })
    }

    @MainActor
    func testMetadataFailureFinishesLoadingInsteadOfLeavingAnEmptyDetail() async throws {
        let fixture = try PresentationFixture(metadataStatus: 503)
        defer { fixture.close() }
        let model = AppModel(client: fixture.api)
        let editor = model.editor(for: "renderNote")
        let host = DetailHost(model: model)
        defer { host.close() }

        try await waitUntil("Metadata failure should reach the mounted detail") {
            editor.failure != nil && !editor.loading
        }
        host.layout()

        XCTAssertNil(editor.note)
        XCTAssertTrue(editor.failure?.contains("503") == true)
        XCTAssertEqual(fixture.requests.map { $0.url?.path }, ["/trilium/etapi/notes/renderNote"])
        XCTAssertGreaterThan(host.controller.view.bounds.width, 0)
        XCTAssertGreaterThan(host.controller.view.bounds.height, 0)
        XCTAssertNil(findWebView(in: host.controller.view), "Failed metadata should show the native error state, not an empty WebView.")
    }

    @MainActor
    func testReopenedDetailReusesCachedEditorAndRendersWithoutRefetching() async throws {
        let fixture = try PresentationFixture()
        defer { fixture.close() }
        let model = AppModel(client: fixture.api)
        let firstHost = DetailHost(model: model)
        defer { firstHost.close() }
        _ = try await waitForBody(in: firstHost, expected: "首次打开：你好 & hello")
        let cachedEditor = model.editor(for: "renderNote")
        firstHost.close()

        let reopenedHost = DetailHost(model: model)
        defer { reopenedHost.close() }
        _ = try await waitForBody(in: reopenedHost, expected: "首次打开：你好 & hello")

        XCTAssertTrue(cachedEditor === model.editor(for: "renderNote"))
        XCTAssertEqual(fixture.requests.count, 2, "Presenting the same clean cached note must not repeat metadata/content requests.")
        XCTAssertNil(cachedEditor.failure)
    }

    @MainActor
    private func waitForBody(in host: DetailHost, expected: String) async throws -> WKWebView {
        // Hosted runners can spend nearly 20 seconds starting WebKit before the document loads.
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        var lastJavaScriptError: String?
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            host.layout()
            if let web = findWebView(in: host.controller.view), web.bounds.width > 0, web.bounds.height > 0 {
                do {
                    let value = try await web.evaluateJavaScript("document.getElementById('note')?.textContent")
                    if value as? String == expected { return web }
                } catch { lastJavaScriptError = error.localizedDescription }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let editor = host.model.editor(for: "renderNote")
        let web = findWebView(in: host.controller.view)
        throw UserFacingError(message: "Detail rendering timed out after 60 seconds. Metadata loaded: \(editor.note != nil); content bytes: \(editor.content.utf8.count); loading: \(editor.loading); failure: \(editor.failure ?? "none"); WebView bounds: \(String(describing: web?.bounds)); JavaScript error: \(lastJavaScriptError ?? "none").")
    }

    @MainActor
    private func waitUntil(_ message: String, condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw UserFacingError(message: message)
    }

    @MainActor
    private func findWebView(in view: UIView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        for child in view.subviews {
            if let web = findWebView(in: child) { return web }
        }
        return nil
    }
}

@MainActor
private final class DetailHost {
    let model: AppModel
    let controller: UIViewController
    private let window: UIWindow
    private var closed = false

    init(model: AppModel) {
        self.model = model
        let root = NavigationStack { NoteDetailView(noteID: "renderNote") }.environmentObject(model)
        controller = UIHostingController(rootView: root)
        let frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
            window.frame = frame
        } else {
            window = UIWindow(frame: frame)
        }
        window.rootViewController = controller
        controller.loadViewIfNeeded()
        controller.view.frame = frame
        window.isHidden = false
        layout()
    }

    func layout() {
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
    }

    func close() {
        guard !closed else { return }
        closed = true
        window.isHidden = true
        window.rootViewController = nil
        controller.view.removeFromSuperview()
    }
}

private final class PresentationFixture: @unchecked Sendable {
    static let body = "<p>首次打开：你好 &amp; hello</p>"
    let api: APIClient
    private let host: String
    private let recorder = Recorder()
    var requests: [URLRequest] { recorder.requests }

    init(metadataStatus: Int = 200) throws {
        host = "detail-\(UUID().uuidString.lowercased()).example.com"
        let baseURL = try XCTUnwrap(URL(string: "https://\(host)/trilium/"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PresentationURLProtocol.self]
        api = APIClient(baseURL: baseURL, token: "presentation-test-token", session: URLSession(configuration: configuration))
        let recorder = self.recorder
        PresentationURLProtocol.registry.register(host: host) { request in
            recorder.append(request)
            switch request.url?.path {
            case "/trilium/etapi/notes/renderNote":
                let metadata = Data("""
                {"noteId":"renderNote","title":"中文测试笔记","type":"text","mime":"text/html",
                 "isProtected":false,"parentNoteIds":["root"],"childNoteIds":[],"childBranchIds":[],
                 "utcDateModified":"2026-09-28 12:00:00.000Z"}
                """.utf8)
                return (metadataStatus, metadata)
            case "/trilium/etapi/notes/renderNote/content": return (200, Data(Self.body.utf8))
            default: throw URLError(.unsupportedURL)
            }
        }
    }

    func close() {
        api.session.invalidateAndCancel()
        PresentationURLProtocol.registry.remove(host: host)
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [URLRequest] = []
        var requests: [URLRequest] {
            lock.lock(); defer { lock.unlock() }
            return recorded
        }
        func append(_ request: URLRequest) {
            lock.lock(); defer { lock.unlock() }
            recorded.append(request)
        }
    }
}

private final class PresentationURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data)
    static let registry = Registry()

    final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var handlers: [String: Handler] = [:]
        func register(host: String, handler: @escaping Handler) {
            lock.lock(); defer { lock.unlock() }
            handlers[host] = handler
        }
        func remove(host: String) {
            lock.lock(); defer { lock.unlock() }
            handlers.removeValue(forKey: host)
        }
        func handler(for host: String) -> Handler? {
            lock.lock(); defer { lock.unlock() }
            return handlers[host]
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let url = request.url, let host = url.host, let handler = Self.registry.handler(for: host) else {
                throw URLError(.unsupportedURL)
            }
            let (status, data) = try handler(request)
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
