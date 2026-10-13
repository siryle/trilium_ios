import Foundation
import XCTest
@testable import TriliumPocket

final class NoteEditorTests: XCTestCase {
    @MainActor
    func testViewsOfSameNoteShareEditorButDifferentNotesDoNot() async {
        let model = AppModel()
        let first = model.editor(for: "sharedNote")
        first.title = "Unsaved title"

        XCTAssertTrue(first === model.editor(for: "sharedNote"))
        XCTAssertEqual(model.editor(for: "sharedNote").title, "Unsaved title")
        XCTAssertFalse(first === model.editor(for: "otherNote"))
    }

    @MainActor
    func testRepeatedLoadPreservesDirtyDraftWithoutFetchingAgain() async throws {
        let fixture = EditorServer()
        let api = try await makeClient { try await fixture.respond(to: $0) }
        let editor = NoteEditorModel()
        defer { cleanup(editor, api: api) }
        await editor.load(id: "sharedNote", api: api, server: api.baseURL.absoluteString)
        XCTAssertNil(editor.failure)
        editor.title = "Local title"
        editor.content = "<p>Local body</p>"
        editor.persistDraft()

        await editor.load(id: "sharedNote", api: api, server: api.baseURL.absoluteString)

        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(editor.title, "Local title")
        XCTAssertEqual(editor.content, "<p>Local body</p>")
        XCTAssertTrue(editor.dirty)
    }

    @MainActor
    func testTitleOnlySaveDoesNotRewriteHTMLContent() async throws {
        let fixture = EditorServer()
        let api = try await makeClient { try await fixture.respond(to: $0) }
        let editor = NoteEditorModel()
        defer { cleanup(editor, api: api) }
        await editor.load(id: "sharedNote", api: api, server: api.baseURL.absoluteString)
        XCTAssertNil(editor.failure)
        editor.editing = true
        editor.title = "Renamed research"

        try await editor.save(api: api)

        let requests = await fixture.requests
        XCTAssertEqual(requests.filter { $0.httpMethod == "PATCH" }.count, 1)
        XCTAssertFalse(requests.contains { $0.httpMethod == "PUT" })
        XCTAssertEqual(editor.content, "<p>Original body</p>")
        XCTAssertFalse(editor.dirty)
        XCTAssertFalse(editor.editing)
        XCTAssertEqual(editor.note?.title, "Renamed research")
    }

    @MainActor
    func testRemoteBodyConflictPreservesLocalDraftAndSendsNoWrites() async throws {
        let fixture = EditorServer()
        let api = try await makeClient { try await fixture.respond(to: $0) }
        let editor = NoteEditorModel()
        defer { cleanup(editor, api: api) }
        await editor.load(id: "sharedNote", api: api, server: api.baseURL.absoluteString)
        XCTAssertNil(editor.failure)
        editor.content = "<p>My local work</p>"
        await fixture.changeRemoteContent("<p>Changed on desktop</p>")

        try await editor.save(api: api)

        let requests = await fixture.requests
        XCTAssertTrue(editor.conflict)
        XCTAssertTrue(editor.dirty)
        XCTAssertEqual(editor.content, "<p>My local work</p>")
        XCTAssertFalse(requests.contains { ["PUT", "PATCH", "POST"].contains($0.httpMethod ?? "") })
    }

    @MainActor
    func testEditsArrivingDuringSaveRemainDirtyAgainstSentSnapshot() async throws {
        let fixture = EditorServer()
        let editor = NoteEditorModel()
        let api = try await makeClient { request in
            if request.httpMethod == "PUT" {
                // Runs after save captured its body and while the request is awaiting a response.
                await MainActor.run { editor.content = "<p>Newer edit arriving during save</p>" }
            }
            return try await fixture.respond(to: request)
        }
        defer { cleanup(editor, api: api) }
        await editor.load(id: "sharedNote", api: api, server: api.baseURL.absoluteString)
        XCTAssertNil(editor.failure)
        editor.editing = true
        editor.content = "<p>Snapshot being saved</p>"

        try await editor.save(api: api)

        let requests = await fixture.requests
        let put = try XCTUnwrap(requests.first { $0.httpMethod == "PUT" })
        XCTAssertEqual(String(data: try requestBody(put), encoding: .utf8), "<p>Snapshot being saved</p>")
        XCTAssertEqual(editor.content, "<p>Newer edit arriving during save</p>")
        XCTAssertTrue(editor.dirty)
        XCTAssertTrue(editor.editing)
        let name = LocalStore.scopedName("note", server: api.baseURL.absoluteString, noteID: "sharedNote")
        let draft = try XCTUnwrap(LocalStore().load(name, as: NoteDraft.self))
        XCTAssertEqual(draft.content, "<p>Newer edit arriving during save</p>")
        XCTAssertEqual(draft.originalContent, "<p>Snapshot being saved</p>")
    }

    @MainActor
    func testComplexHTMLRequiresSourceEditingWhileNormalNotesRemainRichText() async {
        let complex = [
            "<form action='/submit'><input name='name'></form>",
            "<style>p { color: red; }</style><p>Styled</p>",
            "<iframe src='https://example.com'></iframe>",
            "<p onclick='alert(1)'>Interactive</p>",
            "<a href='javascript:alert(1)'>Action</a>"
        ]
        for html in complex { XCTAssertTrue(HTMLText.requiresSourceEditing(html), html) }
        let ordinary = "<h2>Research</h2><p><strong>Bold</strong> and <a href='#root/sharedNote'>reference</a></p><table><tbody><tr><td>Cell</td></tr></tbody></table>"
        XCTAssertFalse(HTMLText.requiresSourceEditing(ordinary))
    }

    private func makeClient(handler: @escaping EditorURLProtocol.Handler) async throws -> APIClient {
        let url = try XCTUnwrap(URL(string: "https://editor-\(UUID().uuidString.lowercased()).example.com/trilium/"))
        await EditorURLProtocol.registry.register(host: try XCTUnwrap(url.host), handler: handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EditorURLProtocol.self]
        return APIClient(baseURL: url, token: "test-token", session: URLSession(configuration: configuration))
    }

    @MainActor
    private func cleanup(_ editor: NoteEditorModel, api: APIClient) {
        editor.discardDraft()
        // The unique server scopes this removal exclusively to the current fixture.
        let name = LocalStore.scopedName("note", server: api.baseURL.absoluteString, noteID: "sharedNote")
        try? LocalStore().remove(name)
        api.session.invalidateAndCancel()
        if let host = api.baseURL.host { Task { await EditorURLProtocol.registry.remove(host: host) } }
    }

    private func requestBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var result = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count == 0 { return result }
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            result.append(contentsOf: bytes.prefix(count))
        }
    }
}

private actor EditorServer {
    private(set) var requests: [URLRequest] = []
    private var content = "<p>Original body</p>"
    private let metadata = Data("""
    {"noteId":"sharedNote","title":"Research","type":"text","mime":"text/html",
     "isProtected":false,"parentNoteIds":["root"],"childNoteIds":[],"childBranchIds":[],
     "utcDateModified":"2026-09-28 12:00:00.000Z"}
    """.utf8)

    func changeRemoteContent(_ value: String) { content = value }

    func respond(to request: URLRequest) throws -> (Int, Data) {
        requests.append(request)
        switch (request.httpMethod, request.url?.path) {
        case ("GET", "/trilium/etapi/notes/sharedNote"): return (200, metadata)
        case ("GET", "/trilium/etapi/notes/sharedNote/content"): return (200, Data(content.utf8))
        case ("PATCH", "/trilium/etapi/notes/sharedNote"): return (200, metadata)
        case ("PUT", "/trilium/etapi/notes/sharedNote/content"): return (204, Data())
        default: throw URLError(.unsupportedURL)
        }
    }
}

private final class EditorURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) async throws -> (Int, Data)
    static let registry = Registry()
    private var responseTask: Task<Void, Never>?

    actor Registry {
        private var handlers: [String: Handler] = [:]
        func register(host: String, handler: @escaping Handler) { handlers[host] = handler }
        func remove(host: String) { handlers.removeValue(forKey: host) }
        func handler(for host: String) -> Handler? { handlers[host] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        responseTask = Task {
            do {
                guard let url = request.url, let host = url.host,
                      let handler = await Self.registry.handler(for: host) else { throw URLError(.unsupportedURL) }
                let (status, data) = try await handler(request)
                try Task.checkCancellation()
                guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)
                else { throw URLError(.badServerResponse) }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }

    override func stopLoading() { responseTask?.cancel() }
}
