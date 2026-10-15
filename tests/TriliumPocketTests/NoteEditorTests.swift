import Foundation
import XCTest
@testable import TriliumPocket

final class NoteEditorTests: XCTestCase {
    @MainActor
    func testQuickCaptureMigratesPlainTextWithoutInterpretingHTML() {
        let text = "今天 <script>alert('日记')</script> & 明天\n第二段记录"
        let draft = QuickCaptureDraft(plainText: text)

        XCTAssertEqual(draft.plainText, text)
        XCTAssertFalse(draft.content.contains("<script>"))
        XCTAssertTrue(draft.content.contains("&lt;script&gt;"))
        XCTAssertEqual(QuickCaptureDraft(plainText: "").content, "")
    }

    @MainActor
    func testQuickCaptureDraftRoundTripPreservesTitleAndRichText() throws {
        let draft = QuickCaptureDraft(title: "今日心得", content: "<h2>工作</h2><p><strong>完成</strong></p><ul><li>明天继续</li></ul>")
        let restored = try JSONDecoder().decode(QuickCaptureDraft.self, from: JSONEncoder().encode(draft))

        XCTAssertEqual(restored, draft)
        XCTAssertEqual(restored.noteTitle(), "今日心得")
        XCTAssertFalse(restored.isEmpty)
    }

    @MainActor
    func testQuickCaptureUntitledNoteUsesVisibleBodyAndIgnoresEmptyEditorMarkup() {
        let draft = QuickCaptureDraft(content: "<p><strong>第一行</strong> &amp; 内容</p><p>第二行</p>")
        XCTAssertTrue(draft.noteTitle().hasSuffix(" · 第一行 & 内容"))
        XCTAssertEqual(QuickCaptureDraft(title: "  自定义标题\n", content: "<p>正文</p>").noteTitle(), "自定义标题")
        XCTAssertTrue(QuickCaptureDraft(content: "<p><br></p><div>&nbsp;</div>").isEmpty)
        XCTAssertFalse(QuickCaptureDraft(title: "只有标题").isEmpty)
    }

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
        let name = LocalStore.scopedName("note", server: api.baseURL.absoluteString, noteID: "sharedNote")
        XCTAssertEqual(LocalStore().load(name, as: NoteDraft.self)?.content, "<p>My local work</p>")
    }

    @MainActor
    func testOverwriteUpdatesOriginalNoteIncludingTitleChangedOnlyOnServer() async throws {
        let fixture = EditorServer()
        let api = try await makeClient { try await fixture.respond(to: $0) }
        let editor = NoteEditorModel()
        defer { cleanup(editor, api: api) }
        await editor.load(id: "sharedNote", api: api, server: api.baseURL.absoluteString)
        editor.editing = true
        editor.content = "<p>My local work</p>"
        await fixture.changeRemoteContent("<p>Changed on desktop</p>")
        await fixture.changeRemoteTitle("Desktop title")
        try await editor.save(api: api)
        XCTAssertTrue(editor.conflict)

        try await editor.save(api: api, overwriteRemote: true)

        let requests = await fixture.requests
        let put = try XCTUnwrap(requests.first { $0.httpMethod == "PUT" })
        let patch = try XCTUnwrap(requests.first { $0.httpMethod == "PATCH" })
        XCTAssertEqual(put.url?.path, "/trilium/etapi/notes/sharedNote/content")
        XCTAssertEqual(String(data: try requestBody(put), encoding: .utf8), "<p>My local work</p>")
        XCTAssertEqual(patch.url?.path, "/trilium/etapi/notes/sharedNote")
        let body = try JSONDecoder().decode([String: String].self, from: requestBody(patch))
        XCTAssertEqual(body, ["title": "Research"])
        XCTAssertFalse(requests.contains { $0.httpMethod == "POST" })
        XCTAssertFalse(editor.conflict)
        XCTAssertFalse(editor.dirty)
        XCTAssertFalse(editor.editing)
        let name = LocalStore.scopedName("note", server: api.baseURL.absoluteString, noteID: "sharedNote")
        XCTAssertNil(LocalStore().load(name, as: NoteDraft.self))
    }

    @MainActor
    func testOverwriteRestoresBodyChangedOnlyOnServer() async throws {
        let fixture = EditorServer()
        let api = try await makeClient { try await fixture.respond(to: $0) }
        let editor = NoteEditorModel()
        defer { cleanup(editor, api: api) }
        await editor.load(id: "sharedNote", api: api, server: api.baseURL.absoluteString)
        editor.title = "My local title"
        await fixture.changeRemoteContent("<p>Desktop body</p>")

        try await editor.save(api: api, overwriteRemote: true)

        let requests = await fixture.requests
        let put = try XCTUnwrap(requests.first { $0.httpMethod == "PUT" })
        XCTAssertEqual(String(data: try requestBody(put), encoding: .utf8), "<p>Original body</p>")
        let remote = try await api.note("sharedNote")
        XCTAssertEqual(remote.title, "My local title")
        XCTAssertFalse(editor.dirty)
    }

    @MainActor
    func testPartiallyFailedOverwriteCanRetryWithoutRewritingSavedBody() async throws {
        let fixture = EditorServer()
        let api = try await makeClient { try await fixture.respond(to: $0) }
        let editor = NoteEditorModel()
        defer { cleanup(editor, api: api) }
        await editor.load(id: "sharedNote", api: api, server: api.baseURL.absoluteString)
        editor.editing = true
        editor.title = "My local title"
        editor.content = "<p>My local body</p>"
        await fixture.changeRemoteTitle("Desktop title")
        await fixture.changeRemoteContent("<p>Desktop body</p>")
        await fixture.failNextTitleUpdate()

        do {
            try await editor.save(api: api, overwriteRemote: true)
            XCTFail("The title update must fail.")
        } catch {
            XCTAssertTrue(editor.dirty)
            XCTAssertTrue(editor.editing)
            XCTAssertFalse(editor.saving)
        }
        let name = LocalStore.scopedName("note", server: api.baseURL.absoluteString, noteID: "sharedNote")
        let draft = try XCTUnwrap(LocalStore().load(name, as: NoteDraft.self))
        XCTAssertEqual(draft.originalTitle, "Desktop title")
        XCTAssertEqual(draft.originalContent, "<p>My local body</p>")
        XCTAssertEqual(draft.title, "My local title")

        try await editor.save(api: api)

        let requests = await fixture.requests
        XCTAssertEqual(requests.filter { $0.httpMethod == "PUT" }.count, 1)
        XCTAssertEqual(requests.filter { $0.httpMethod == "PATCH" }.count, 2)
        XCTAssertFalse(editor.conflict)
        XCTAssertFalse(editor.dirty)
        XCTAssertFalse(editor.editing)
        XCTAssertNil(LocalStore().load(name, as: NoteDraft.self))
    }

    @MainActor
    func testDeleteRemovesServerNoteAndDraftAndPreventsStaleEditorWrites() async throws {
        let fixture = EditorServer()
        let api = try await makeClient { try await fixture.respond(to: $0) }
        let model = AppModel(client: api)
        let editor = model.editor(for: "sharedNote")
        defer { cleanup(editor, api: api) }
        await editor.load(id: "sharedNote", api: api, server: api.baseURL.absoluteString)
        model.contextNote = editor.note
        model.contextContent = editor.content
        editor.editing = true
        editor.content = "<p>Unsaved body</p>"
        editor.persistDraft()
        let name = LocalStore.scopedName("note", server: api.baseURL.absoluteString, noteID: "sharedNote")
        XCTAssertNotNil(LocalStore().load(name, as: NoteDraft.self))

        try await editor.delete(api: api)
        model.didDeleteNote("sharedNote")
        editor.content = "<p>Late WebKit edit</p>"
        editor.persistDraft()
        try await editor.save(api: api)
        await editor.load(id: "sharedNote", api: api, server: api.baseURL.absoluteString)
        await editor.reload(id: "sharedNote", api: api, server: api.baseURL.absoluteString)

        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests.last?.httpMethod, "DELETE")
        XCTAssertEqual(requests.last?.url?.path, "/trilium/etapi/notes/sharedNote")
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Authorization"), "test-token")
        XCTAssertTrue(editor.deleted)
        XCTAssertFalse(editor.deleting)
        XCTAssertFalse(editor.dirty)
        XCTAssertFalse(editor.editing)
        XCTAssertNil(LocalStore().load(name, as: NoteDraft.self))
        XCTAssertTrue(editor === model.editor(for: "sharedNote"))
        XCTAssertTrue(model.isNoteDeleted("sharedNote"))
        XCTAssertFalse(model.isNoteDeleted("otherNote"))
        XCTAssertNil(model.contextNote)
        XCTAssertNil(model.contextContent)
        XCTAssertEqual(model.changeVersion, 1)
    }

    @MainActor
    func testFailedDeletePreservesEditorAndDraft() async throws {
        let fixture = EditorServer(deleteStatus: 403)
        let api = try await makeClient { try await fixture.respond(to: $0) }
        let editor = NoteEditorModel()
        defer { cleanup(editor, api: api) }
        await editor.load(id: "sharedNote", api: api, server: api.baseURL.absoluteString)
        editor.editing = true
        editor.content = "<p>Unsaved body</p>"
        editor.persistDraft()

        do {
            try await editor.delete(api: api)
            XCTFail("The server must reject deletion.")
        } catch {
            XCTAssertFalse(editor.deleted)
            XCTAssertFalse(editor.deleting)
            XCTAssertTrue(editor.editing)
            XCTAssertTrue(editor.dirty)
        }
        let name = LocalStore.scopedName("note", server: api.baseURL.absoluteString, noteID: "sharedNote")
        XCTAssertEqual(LocalStore().load(name, as: NoteDraft.self)?.content, "<p>Unsaved body</p>")
    }

    func testRootCannotBeDeleted() async throws {
        let fixture = EditorServer()
        let api = try await makeClient { try await fixture.respond(to: $0) }
        defer {
            api.session.invalidateAndCancel()
            if let host = api.baseURL.host { Task { await EditorURLProtocol.registry.remove(host: host) } }
        }
        do {
            try await api.deleteNote("root")
            XCTFail("Root deletion must be rejected locally.")
        } catch {
            let requests = await fixture.requests
            XCTAssertTrue(requests.isEmpty)
        }
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

    @MainActor
    func testEscapedCodeAndAttributeDescriptionsRemainRichTextEditable() {
        let ordinary = [
            "<pre><code>&lt;img src=x onerror=alert(1)&gt;</code></pre>",
            "<p>Examples: onclick='alert(1)', srcset=x, action=/submit, href=javascript:alert.</p>",
            #"<p title="Examples: onclick='alert(1)' href='javascript:alert' >">Description</p>"#,
            #"<a href="https://example.com/?hint=onclick">Link</a>"#,
            "<p>UTF-8: \u{4F60}\u{597D}</p><br />"
        ]
        for html in ordinary { XCTAssertFalse(HTMLText.requiresSourceEditing(html), html) }
    }

    @MainActor
    func testActualUnsupportedAttributesAndLinksStillRequireSourceEditing() {
        let complex = [
            #"<img src="local" onerror="alert(1)">"#,
            #"<p title="Literal > text" ONCLICK="alert(1)">Interactive</p>"#,
            #"<img srcset="a.png 1x, b.png 2x">"#,
            #"<p contenteditable="true">Editable</p>"#,
            #"<img data-trilium-original-src="local">"#,
            #"<img data-trilium-original-alt="original">"#,
            #"<button formaction="/submit">Submit</button>"#,
            #"<a HREF=" JAVASCRIPT:alert(1) ">Unsafe</a>"#,
            #"<a href=https://example.com>Unquoted</a>"#,
            #"<p title="Description"onclick="alert(1)">Malformed</p>"#,
            #"<img onerror="unterminated"#,
            #"<script src="unterminated"#
        ]
        for html in complex { XCTAssertTrue(HTMLText.requiresSourceEditing(html), html) }
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

private actor EditorServer {
    private(set) var requests: [URLRequest] = []
    private var content = "<p>Original body</p>"
    private var title = "Research"
    private var shouldFailTitleUpdate = false
    private let deleteStatus: Int
    private var metadata: Data { Data("""
    {"noteId":"sharedNote","title":"\(title)","type":"text","mime":"text/html",
     "isProtected":false,"parentNoteIds":["root"],"childNoteIds":[],"childBranchIds":[],
     "utcDateModified":"2026-09-28 12:00:00.000Z"}
    """.utf8) }

    init(deleteStatus: Int = 204) { self.deleteStatus = deleteStatus }
    func changeRemoteContent(_ value: String) { content = value }
    func changeRemoteTitle(_ value: String) { title = value }
    func failNextTitleUpdate() { shouldFailTitleUpdate = true }

    func respond(to incomingRequest: URLRequest) throws -> (Int, Data) {
        var request = incomingRequest
        if request.httpBody != nil || request.httpBodyStream != nil {
            request.httpBody = try requestBody(request)
        }
        requests.append(request)
        switch (request.httpMethod, request.url?.path) {
        case ("GET", "/trilium/etapi/notes/sharedNote"): return (200, metadata)
        case ("GET", "/trilium/etapi/notes/sharedNote/content"): return (200, Data(content.utf8))
        case ("PATCH", "/trilium/etapi/notes/sharedNote"):
            if shouldFailTitleUpdate { shouldFailTitleUpdate = false; return (500, Data()) }
            let fields = try JSONDecoder().decode([String: String].self, from: requestBody(request))
            title = fields["title"] ?? title
            return (200, metadata)
        case ("PUT", "/trilium/etapi/notes/sharedNote/content"):
            content = String(data: try requestBody(request), encoding: .utf8) ?? ""
            return (204, Data())
        case ("DELETE", "/trilium/etapi/notes/sharedNote"): return (deleteStatus, Data())
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
